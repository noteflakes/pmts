# PMTS - Poor man's time series functionality for PostgreSQL

PMTS is a collection of tools for working with time-series data in PostgreSQL written in SQL and PL/pgSQL, without needing to install extensions or work with outside tools. Its features include:

- Automatic partitioning (sharding) of time-series tables by time range.
- Automatic dropping of old partitions according to data retention settings.
- Aggregation and summarizing utilities (WIP).

PMTS delivers many of the benefits of using tools such as TimeScaleDB or CitusDB on a stock PostgreSQL setup. PMTS has been employed successfuly in a 1TB production database with hundreds of tables and billions of time-series records.

## Getting Started

After installing PMTS, create a sample table and start working with it.

```SQL
-- create our time-series table
create table measurements (sensor text, stamp timestamptz, value numeric);

-- setup partitioning with per-week partitioning, retaining data for one year.
-- we also provide any index fields in order for PMTS to setup an index on relevant columns.
-- in this case, PMTS will create an index on (sensor, stamp).
select pmts_setup_partitions('measurements', 86400 * 7, 86400 * 365, '{sensor}');

-- continue to work normally with our table
insert into measurements values ('temp', now(), 12.345);

select stamp, value from measurements where sensor = 'temp' and stamp >= now() - interval '1 month';
```
## API

The PMTS API is made of PL/pgSQL functions. Those functions can be called just like any built-in function using `select`:

```SQL
[dbuser] # select pmts_setup_partitions(...);
```

You can also invoke these functions from your shell:

```bash
$ psql -c "select pmts_setup_partitions(...);"
```

### pmts_setup_partitions(tbl_name, partition_size, retention_period, index_fields)

Sets up partitioning for the specified table. PMTS will use the supplied arguments to control partition creation and deletion. Partitions are created on the fly by using an insert trigger. The trigger will create partitions as needed and insert records into the correct partition.

#### Arguments

Name|Type|Description
----|----|-----------
tbl_name|TEXT|Identifier of table to be partitioned
partition_size|INTEGER|The partition size in seconds
retention_period|INTEGER|The retention period in seconds
index_fields|TEXT[]|An array of fields to use for indexing

PMTS partitions tables by time ranges. The `partition_size` argument controls the size of each partitions in terms of time range. The `retention_period` argument is used to control how the amount of time to retain old data.

The `index_fields` argument is used to control the index created automatically by PMTS. By default, if no index fields are specified, PMTS will create an index on the `stamp` field for each created partition. In most cases, though, A compound index will be more useful, as usually data is filtered not only by time range but also by one or more dimensions in other columns.

For example, consider the following scenario:

```SQL
create table measurements (unit text, metric text, stamp timestamptz, value numeric);
```

In such a case, we'll usually query by unit, metric *and* stamp. We therefore pass the relevant columns to PMTS:

```SQL
select pmts_setup_partitions ('measurements', 86400 * 7, 86400 * 365, '{unit, metric}');
```

PMTS will then create an index on `(unit, metric, stamp)` for each partition.

### pmts_drop_old_partitions()

Drops old partitions according to retention period specified for each table. This function should be called periodically to remove old partitions. Use your favorite to setup a recurring job that invokes the function.

### pmts_total_size(tbl_name)

Returns the sum of total relation size for all partitions of the specified table using `pg_total_relation_size`.

#### Arguments

Name|Type|Description
----|----|-----------
tbl_name|TEXT|Table name

### pmts_info

A view returning total size and number of partitions for each table managed by PMTS.

## FAQ

**Q:** What is a time series table?

**A:** For PMTS, any table that includes a `stamp` column, of type `timestamp` or `timestamptz`.

**Q:** Why should I partition (or shard) my time series tables?

**A:** Partitioning a table allows you to keep your tables to a manageable size and maintain a good insertion rate. It also makes it easier to get rid of old data by simply dropping partitions instead of deleting recores and then vacuuming.

**Q:** How does partitioning work?

**A:** For each partitioned table, PMTS maintains a list of partitions and installs an insert trigger that will insert each record into the correct partition according to the time stamp. Partition tables are created using PostgreSQL's table inheritance mechanism. That way, the query planner will automatically include and exclude partition tables according to the time range specified for the query.

**Q:** What versions of PostgreSQL can be used with PMTS?

**A:** PMTS has been developed and used on PostgreSQL 9.6. It will most probably not work with anything before 9.0.

**Q:** How do I install it?

**A:** Simply download `pmts.sql` and load into your database using `psql`:

    $ psql -f pmts.sql

**Q:** Does PMTS work in AWS RDS?

**A:** Yes.

**Q:** Do I need to install anything besides PostgreSQL for PMTS to work?

**A:** No.

## Disclaimer

This is unstable code, might contain bugs, might  and might destroy your data. Use in production at your own risk.

