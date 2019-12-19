-- PMTS - Poor man's time-series functionality for PostgreSQL
-- (c) 2018-2019 Sharon Rosner

BEGIN;

------------------------
-- Internal functions --
------------------------

-- pmts_time_align: returns time stamp aligned to an arbitrary time interval
CREATE OR REPLACE FUNCTION pmts_time_align (stamp TIMESTAMPTZ, quant INTEGER)
  RETURNS TIMESTAMPTZ
AS $$
BEGIN
  RETURN TO_TIMESTAMP(EXTRACT(EPOCH FROM stamp)::INTEGER / quant * quant);
END;
$$
LANGUAGE plpgsql;

----------------------
-- Tables and Views --
----------------------

-- pmts_tables: holds information on tables managed by PMTS
CREATE TABLE IF NOT EXISTS pmts_tables (
  tbl_name TEXT UNIQUE NOT NULL,
  partition_size INTEGER,
  retention_period INTEGER
);

-- pmts_partitions: holds information on individual partitions
CREATE TABLE IF NOT EXISTS pmts_partitions (
  tbl_name TEXT NOT NULL,
  stamp_min TIMESTAMPTZ,
  stamp_max TIMESTAMPTZ,
  partition_name TEXT UNIQUE NOT NULL
);
CREATE INDEX ON pmts_partitions (tbl_name, stamp_min, stamp_max);

-- pmts_info: view showing stats for partitioned tables
CREATE OR REPLACE VIEW pmts_info AS 
WITH p AS (
  SELECT tbl_name, partition_name FROM pmts_partitions 
)
SELECT
  t.tbl_name,
  coalesce(sum(pg_total_relation_size(p.partition_name)), 0) as total_size,
  count(p.partition_name) as partition_count,
  case when count(p.partition_name) = 0 
    then 0 
    else sum(pg_total_relation_size(p.partition_name))::bigint / count(p.partition_name) 
  end as avg_size,
  max(t.partition_size) as partition_size
FROM pmts_tables t LEFT JOIN p ON p.tbl_name = t.tbl_name
GROUP BY t.tbl_name;

-- pmts_next_partitions_to_create: view containing the next partitions that need
-- to be created for values in the next 3 days
DROP view IF EXISTS pmts_next_partitions_to_create;
CREATE view pmts_next_partitions_to_create AS WITH latest_partitions AS (
  SELECT DISTINCT ON (pmts_tables.tbl_name)
    pmts_tables.tbl_name,
    pmts_tables.partition_size,
    coalesce(
      pmts_partitions.stamp_max,
      pmts_time_align (now(), pmts_tables.partition_size)
    ) AS next_partition_min
  FROM pmts_tables
  LEFT JOIN pmts_partitions ON pmts_tables.tbl_name = pmts_partitions.tbl_name
  ORDER BY pmts_tables.tbl_name, pmts_partitions.stamp_max DESC
),
next_partitions AS (
  SELECT
    *,
    next_partition_min + format(
      '%s seconds', partition_size
    )::interval AS next_partition_max,
    EXTRACT(EPOCH FROM next_partition_min)::INTEGER /
      partition_size AS partition_id
  FROM latest_partitions
)
SELECT
  format('%s_p_%s_%s', tbl_name, partition_size, partition_id) as partition_name,
  tbl_name,
  next_partition_min,
  next_partition_max
FROM next_partitions
WHERE next_partition_min < now() - interval '3 days';

----------
-- APIs --
----------

-- pmts_setup: sets up partitioning for a given table
-- table should already be defined as partitioned table
CREATE OR REPLACE FUNCTION pmts_setup (
  tbl_name TEXT, 
  partition_size INTEGER DEFAULT 86400, 
  retention_period INTEGER DEFAULT 86400 * 365)
  RETURNS void
AS $$
BEGIN
  INSERT INTO pmts_tables
  VALUES (tbl_name, partition_size, retention_period);

  PERFORM pmts_create_new_partitions();
END;
$$
LANGUAGE plpgsql;

-- pmts_drop_table: drops a table and all its partitions, remove records from
-- pmts_tables and pmts_partitions
CREATE OR REPLACE FUNCTION pmts_drop_table (tbl TEXT)
  RETURNS VOID
AS $$
BEGIN
  DELETE FROM pmts_partitions WHERE tbl_name = tbl;
  DELETE FROM pmts_tables WHERE tbl_name = tbl;
  EXECUTE FORMAT('DROP TABLE %I CASCADE', tbl);
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pmts_drop_old_partitions ()
  RETURNS INTEGER
AS $$
DECLARE
  ROW pmts_partitions;
  counter INTEGER;
BEGIN
  counter = 0;
  FOR ROW IN
    DELETE FROM
      pmts_partitions p USING pmts_tables t
    WHERE
      p.tbl_name = t.tbl_name
    AND
      stamp_max < NOW() - (t.retention_period * INTERVAL '1 second')
    RETURNING *
  LOOP
    counter = counter + 1;
    EXECUTE FORMAT('drop table %I', ROW.partition_name);
    RAISE NOTICE 'Dropped partition %.', ROW.partition_name;
  END LOOP;
  RETURN counter;
END;
$$
LANGUAGE plpgsql;

-- pmts_create_new_partitions: creates new partitions from
-- pmts_next_partitions_to_create view
CREATE OR REPLACE FUNCTION pmts_create_new_partitions ()
  RETURNS INTEGER
AS $$
DECLARE
  ROW pmts_next_partitions_to_create;
  counter INTEGER;
  partition_creation_sql CONSTANT TEXT := '
    CREATE TABLE IF NOT EXISTS %I PARTITION OF %I
    FOR VALUES FROM (%L) TO (%L);
  ';
BEGIN
  counter = 0;
  FOR ROW IN
    SELECT * FROM pmts_next_partitions_to_create
  LOOP
    counter = counter + 1;

    EXECUTE FORMAT(partition_creation_sql,
      ROW.partition_name,
      ROW.tbl_name,
      ROW.next_partition_min,
      ROW.next_partition_max
    );
    INSERT INTO pmts_partitions VALUES (
      ROW.tbl_name,
      ROW.next_partition_min,
      ROW.next_partition_max,
      ROW.partition_name
    );
    raise notice 'Created partition %.', ROW.partition_name;
  END LOOP;
  RETURN counter;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pmts_create_all_partitions(tbl TEXT)
  RETURNS INTEGER
AS $$
DECLARE
  tbl_settings pmts_tables;
  counter INTEGER;
  partition_size INTEGER;
  retention_period INTEGER;
  stamp TIMESTAMPTZ;
  stamp_threshold TIMESTAMPTZ;

  stamp_min TIMESTAMPTZ;
  stamp_max TIMESTAMPTZ;
  partition_name TEXT;
  partition_id INTEGER;

  partition_creation_sql CONSTANT TEXT := '
    CREATE TABLE IF NOT EXISTS %I PARTITION OF %I
    FOR VALUES FROM (%L) TO (%L);
    INSERT INTO pmts_partitions VALUES (%2$L, %3$L, %4$L, %1$L) ON CONFLICT DO NOTHING;
  ';
BEGIN
  counter = 0;
  SELECT * INTO tbl_settings
  FROM pmts_tables
  WHERE tbl_name = tbl;

  partition_size = tbl_settings.partition_size;
  retention_period = tbl_settings.retention_period;

  stamp = now();
  stamp_threshold = stamp - format('%s seconds', retention_period)::interval;

  LOOP
    stamp_min = pmts_time_align (stamp, partition_size);
    stamp_max = stamp_min + FORMAT('%s seconds', partition_size)::INTERVAL;
    partition_id = EXTRACT(EPOCH FROM stamp_min)::INTEGER / partition_size;
    partition_name = FORMAT('%s_p_%s_%s',
      tbl,
      partition_size,
      partition_id
    );
    EXECUTE FORMAT(partition_creation_sql,
      partition_name,
      tbl,
      stamp_min,
      stamp_max
    );
    counter = counter + 1;
    raise notice 'Created partition %.', partition_name;
    stamp = stamp - format('%s seconds', partition_size)::interval;
    EXIT WHEN stamp < stamp_threshold;
  END LOOP;

  RETURN counter;
END;
$$
LANGUAGE plpgsql;

-- pmts_total_size: returns total size of given table's partitions
CREATE OR REPLACE FUNCTION pmts_total_size(tbl_name TEXT) RETURNS numeric
AS $$
  SELECT sum(pg_total_relation_size(partition_name)) as total_size
  FROM pmts_partitions
  WHERE tbl_name = $1;
$$ language sql;

-- pmts_ideal_partition_size: returns ideal partition size
CREATE OR REPLACE FUNCTION pmts_ideal_partition_size(
  desired_byte_size BIGINT,
  current_byte_size BIGINT, 
  current_partition_size BIGINT,
  min_days INT DEFAULT 7,
  max_days INT DEFAULT 56
) RETURNS BIGINT
AS $$
DECLARE
  day_byte_size BIGINT;
  desired_days BIGINT;
BEGIN
  IF current_byte_size = 0 THEN
    RETURN NULL;
  END IF;
  day_byte_size = (current_byte_size::float / (current_partition_size / 86400))::bigint;
  desired_days = greatest(least(round(desired_byte_size / day_byte_size), max_days), min_days);
  RETURN desired_days * 86400;
END;
$$ language plpgsql;

-- pmts_tune_partition_size: tunes partition sizes for all tables
CREATE OR REPLACE FUNCTION pmts_tune_partition_size(
  desired_byte_size BIGINT,
  min_days INT DEFAULT 7,
  max_days INT DEFAULT 56
) RETURNS VOID
AS $$
UPDATE
  pmts_tables t
SET
  partition_size = coalesce(
    pmts_ideal_partition_size(
      desired_byte_size,
      i.avg_size,
      t.partition_size,
      min_days,
      max_days
    ),
    t.partition_size)
FROM
  pmts_info i
WHERE
  t.tbl_name = i.tbl_name
AND
  i.partition_count > 0;
$$ language sql;

-- pmts_version: returns PMTS version
CREATE OR REPLACE FUNCTION pmts_version() RETURNS TEXT
AS $$
BEGIN
  RETURN '2.0';
END
$$ language plpgsql;

DO $$
BEGIN
  RAISE NOTICE 'PMTS Version % at your service!', pmts_version();
END $$;

COMMIT;