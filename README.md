# PMTS - Poor man's time series functionality for PostgreSQL

PMTS is a collection of tools for working with time-series data in PostgreSQL written in SQL and PL/pgSQL, without needing to install extensions or work with outside tools. Its features include:

- Automatic partitioning (sharding) of time-series tables by time range.
- Automatic dropping of old partitions according to data retention settings.
- Aggregation and summarizing utilities.

PMTS delivers many of the benefits of using tools such as TimeScaleDB or CitusDB on a stock PostgreSQL setup. PMTS has been employed successfuly in a 1TB production database with hundreds of tables and billions of time-series records.

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

