-- PMTS - Poor man's time-series functionality for PostgreSQL
-- (c) 2018 Sharon Rosner

CREATE TABLE IF NOT EXISTS pmts_tables (
  tbl_name TEXT UNIQUE NOT NULL,
  partition_size INTEGER,
  retention_period INTEGER,
  index_fields TEXT [ ]
);

CREATE TABLE IF NOT EXISTS pmts_partitions (
  tbl_name TEXT NOT NULL,
  stamp_min TIMESTAMPTZ,
  stamp_max TIMESTAMPTZ,
  partition_name TEXT UNIQUE NOT NULL
);
CREATE INDEX ON pmts_partitions (tbl_name, stamp_min, stamp_max);

CREATE OR REPLACE FUNCTION pmts_time_round (stamp TIMESTAMPTZ, quant INTEGER)
  RETURNS TIMESTAMPTZ
AS $$
BEGIN
  RETURN TO_TIMESTAMP(EXTRACT(EPOCH FROM stamp)::INTEGER / quant * quant);
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pmts_insert_trigger ()
  RETURNS TRIGGER
AS $$
DECLARE
  partition_name TEXT;
  stamp_min TIMESTAMPTZ;
  stamp_max TIMESTAMPTZ;
  partition_size INTEGER;
  partition_ref INTEGER;
  index_fields TEXT [];
  partition_creation_sql CONSTANT TEXT := '
    CREATE TABLE %I
      (CHECK (stamp >= %3$L and stamp < %4$L))
    INHERITS (%2$I);
    CREATE INDEX ON %1$I (%5$s);
  ';
BEGIN
  SELECT
    p.partition_name INTO partition_name
  FROM
    pmts_partitions p
  WHERE
    tbl_name = TG_TABLE_NAME
    AND NEW.stamp >= p.stamp_min
    AND NEW.stamp < p.stamp_max;
  
  IF NOT FOUND THEN
    -- create partition according 
    SELECT
      t.partition_size,
      t.index_fields 
    INTO
      partition_size, 
      index_fields
    FROM
      pmts_tables t
    WHERE
      tbl_name = TG_TABLE_NAME;
    
    stamp_min = pmts_time_round (NEW.stamp, partition_size);
    stamp_max = stamp_min + FORMAT('%s seconds', partition_size)::INTERVAL;
    partition_ref = EXTRACT(EPOCH FROM stamp_min)::INTEGER / partition_size;
    partition_name = FORMAT('%s_p_%s_%s', TG_TABLE_NAME, partition_size, partition_ref);

    INSERT INTO pmts_partitions
    VALUES (TG_TABLE_NAME, stamp_min, stamp_max, partition_name);
    
    EXECUTE FORMAT(partition_creation_sql,
      partition_name,
      TG_TABLE_NAME,
      stamp_min,
      stamp_max,
      ARRAY_TO_STRING(index_fields || '{stamp}', ',')
    );
    raise notice 'Created partition %.', partition_name;
  END IF;

  EXECUTE FORMAT('insert into %I values ($1.*)', partition_name) USING NEW;
  RETURN NULL;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pmts_setup_partitions (
  tbl_name TEXT, 
  partition_size INTEGER DEFAULT 86400, 
  retention_period INTEGER DEFAULT 86400 * 365, 
  index_fields TEXT [ ] DEFAULT '{}')
  RETURNS void
AS $$
DECLARE
  trigger_sql CONSTANT TEXT := '
    DROP TRIGGER IF EXISTS %1$I on %2$I;
    CREATE TRIGGER %1$I BEFORE INSERT ON %2$I
    FOR EACH ROW EXECUTE PROCEDURE pmts_insert_trigger();
  ';
BEGIN
  INSERT INTO pmts_tables
  VALUES (tbl_name, partition_size, retention_period, index_fields);
  EXECUTE FORMAT(trigger_sql,
    FORMAT('%s_insert_trigger', tbl_name),
    tbl_name);
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

CREATE OR REPLACE FUNCTION pmts_total_size(tbl_name TEXT) RETURNS numeric
AS $$
  SELECT sum(pg_total_relation_size(partition_name)) as total_size
  FROM pmts_partitions
  WHERE tbl_name = $1;
$$ language sql;

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

-------------------------------------------

CREATE FUNCTION pmts_version() RETURNS TEXT
AS $$
BEGIN
  RETURN '0.3';
END
$$ language plpgsql;

DO $$
BEGIN
  RAISE NOTICE 'PMTS Version % at your service!', pmts_version();
END $$;
