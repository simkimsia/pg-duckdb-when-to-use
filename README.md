# pg-duckdb-when-to-use

When does [pg_duckdb](https://github.com/duckdb/pg_duckdb) actually make your Postgres
queries faster, and when does it make them slower? This repo is a small benchmark you can run
with one command, plus what I learned from running it.

The write-up with the story behind it:
[pg_duckdb: When Do I Actually Need It?](https://simkimsia.com/notes/pg-duckdb-when-to-use/)

## The short answer

| Your situation | Use pg_duckdb? |
|---|---|
| Tables under ~1M rows | **No.** Every query finished under 0.6 s either way. |
| ~10M rows, reports that group by something with many values (per customer), `COUNT(DISTINCT)`, window functions | **Yes.** 5 s became 1.2 s. About 4× faster. |
| Simple rollups with few groups (daily totals) | **No.** pg_duckdb was 2× **slower**. |
| Join + `GROUP BY` | Doesn't matter. It was a tie. |
| ~50M rows (3 GB) and up, on normal Postgres tables | Gains drop to about 2×. Put the data in Parquet and it's 6 to 20×. |
| Normal app traffic: lookups by id, inserts, updates | **No.** That is what Postgres is for. |

## Hardware

Every number below comes from this machine. Your numbers will differ. Run it and compare.

| | |
|---|---|
| Machine | MacBook Pro (MacBookPro18,4), Apple M1 Max |
| CPU | 10 cores (8 performance + 2 efficiency) |
| RAM | 64 GB |
| OS | macOS 15.7.5 |
| Docker | 29.8.2 on OrbStack 2.2.5, all 10 CPUs and ~47 GB visible to containers |
| Database | Postgres 18.1 + pg_duckdb 1.1.0 (image `pgduckdb/pgduckdb:18-v1.1.1`) |
| Postgres settings | `shared_buffers=4GB`, `work_mem=256MB`, `max_parallel_workers_per_gather=4` |

Full output: [results/kimsia-m1max-2026-10-30/hardware.txt](results/kimsia-m1max-2026-10-30/hardware.txt).

## Run it yourself

You need Docker and about 10 GB of free disk. It takes 15 to 20 minutes.

```bash
git clone https://github.com/simkimsia/pg-duckdb-when-to-use.git
cd pg-duckdb-when-to-use
./run.sh
```

Results land in `results/<your-machine>-<date>/`. Clean up with `docker rm -f pgduck-bench`.

To rerun only the benchmark on a container you already loaded:

```bash
./bench.sh                 # all sizes
SIZES=1m ./bench.sh        # quick smoke test, about 10 seconds
```

If your pattern looks different from mine, please open an issue with your `results.csv` and
`hardware.txt`. That is the most useful thing this repo can collect.

## What it measures

**Data.** A fake `orders` table at 1M rows (57 MB), 10M rows (575 MB) and 50M rows (2.9 GB),
plus a 1M-row `customers` table. See [sql/setup.sql](sql/setup.sql).

**Queries.** Four shapes you find behind a dashboard. See [bench.sh](bench.sh).

1. `daily`: `GROUP BY order_date`. About 2,000 groups.
2. `per_customer`: `GROUP BY customer_id` with `COUNT(DISTINCT product_id)`. About 1M groups.
3. `join`: orders joined to customers, grouped by region and status.
4. `window`: `rank() OVER (PARTITION BY customer_id ORDER BY amount DESC)`.

**Engines.**

1. `postgres`: `duckdb.force_execution = false`.
2. `duckdb`: `duckdb.force_execution = true`, every other setting default.
3. `duckdb-tuned`: same, plus `duckdb.threads_for_postgres_scan = 8` and
   `duckdb.max_workers_per_postgres_scan = 4`.

Each cell runs 3 times in one session. The median is kept. The cache is warm.

## Results

Seconds. Raw numbers: [results.csv](results/kimsia-m1max-2026-10-30/results.csv).

| Query | Rows | postgres | duckdb | duckdb-tuned |
|---|---|---|---|---|
| daily | 1M | 0.05 | 0.07 | 0.08 |
| daily | 10M | 0.36 | 0.60 | 0.63 |
| daily | 50M | 1.59 | 3.26 | 3.10 |
| per_customer | 1M | 0.59 | 0.14 | 0.15 |
| per_customer | 10M | 5.03 | 1.19 | 1.00 |
| per_customer | 50M | 13.89 | 7.94 | 6.05 |
| join | 1M | 0.22 | 0.21 | 0.19 |
| join | 10M | 1.25 | 1.21 | 1.19 |
| join | 50M | 5.73 | 5.46 | 5.36 |
| window | 1M | 0.50 | 0.11 | 0.09 |
| window | 10M | 5.36 | 1.52 | 0.81 |
| window | 50M | 11.77 | 5.05 | 4.26 |

The same 50M rows as Parquet (808 MB), read with `read_parquet()`
([sql/parquet.sql](sql/parquet.sql), [parquet.txt](results/kimsia-m1max-2026-10-30/parquet.txt)):

| Query | Postgres table | Parquet via pg_duckdb |
|---|---|---|
| daily | 1.59 s | 0.08 s |
| per_customer | 13.89 s | 2.24 s |

## How pg_duckdb works, and why the numbers look like this

Source links point at commit
[a9457c9](https://github.com/duckdb/pg_duckdb/tree/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d)
(28 Oct 2026). That is a few commits newer than the 1.1.0 release I benchmarked, so a line
or two may differ.

### It takes over the query, not the table

pg_duckdb hooks into the Postgres
[planner and executor](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/pgduckdb_hooks.cpp#L506-L524).
When DuckDB takes a query, the whole query becomes a single `Custom Scan (DuckDBScan)` node.
`EXPLAIN` shows DuckDB's own plan inside it.

DuckDB takes a query when:

1. `duckdb.force_execution` is on and the query is a `SELECT` with a `FROM`, or
2. the query uses something only DuckDB has, like `read_parquet()` or a DuckDB table.

If DuckDB cannot plan a query in case 1, it prints a
[WARNING and hands the query back to Postgres](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/pgduckdb_planner.cpp#L353-L363).

### It does not read your heap table itself

This is the part that explains the whole benchmark. For each Postgres table in the query,
pg_duckdb
[builds a plain `SELECT columns FROM table WHERE ...`](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/scan/postgres_scan.cpp#L339-L426)
and
[runs it through the normal Postgres executor](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/scan/postgres_table_reader.cpp#L55-L85).
Each row that comes back is converted, value by value, into DuckDB vectors. Columns and simple
`WHERE` filters are pushed down. Joins and `GROUP BY` never are.

The read is parallel, but narrow by default:

1. `duckdb.max_workers_per_postgres_scan` (default 2) launches real Postgres parallel workers.
   It is 1 worker if the table is estimated at 65,536 rows or fewer
   ([source](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/scan/postgres_table_reader.cpp#L220-L231)).
   `max_parallel_workers_per_gather` is not used here.
2. `duckdb.threads_for_postgres_scan` (default 2) is how many DuckDB threads pull rows from
   those workers. It only applies if at least one worker launched
   ([source](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/scan/postgres_scan.cpp#L440-L450)).

So every pg_duckdb query on a Postgres table has two halves. **Delivery**: Postgres reads the
rows and hands them over. **Work**: DuckDB groups, counts and ranks on all cores.

### Reading the results through that lens

1. **daily lost.** The work is tiny, 2,000 groups. Plain Postgres runs a partial aggregate
   in 4 workers plus the leader and only moves about 8,000 partial rows. pg_duckdb has to
   deliver all 50M rows first. Opening the scan up did not help.
2. **per_customer and window won.** The work is the expensive half. Postgres sorts in
   parallel, but the `GroupAggregate` with `COUNT(DISTINCT)` and the `WindowAgg` run above
   the `Gather Merge`, in one process. DuckDB runs that part vectorized on all cores.
3. **join tied.** Both engines spend most of the time reading and matching the same rows.
4. **Gains shrank at 50M.** Delivery became the bottleneck. More scan workers and threads
   (`duckdb-tuned`) helped: per_customer 7.9 s → 6.0 s, window 5.0 s → 4.3 s. A second
   possible cause is the 4 GB per-connection `duckdb.max_memory` making DuckDB spill to disk.
   I did not test that separately.
5. **Parquet flew.** `read_parquet()` skips the Postgres delivery step. The file is columnar
   and DuckDB reads it with every thread.

Points 1 to 4 are my reading of the source plus `EXPLAIN` output. I did not profile them.

## Gotchas

1. **Plain `numeric` quietly turns pg_duckdb off.** A column with no precision becomes an
   [unsupported type](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/pgduckdb_types.cpp#L1358-L1368).
   DuckDB refuses the query, prints a WARNING, and Postgres runs it instead. The answer is
   still correct, so it is easy to miss. Use `numeric(p,s)`.
   `duckdb.convert_unsupported_numeric_to_double` also works, but you lose exact decimals.
   Reproduce it with [sql/numeric-gotcha.sql](sql/numeric-gotcha.sql). My own first run was
   all Postgres because of this.
2. **Table scans default to 2 workers and 2 threads**, whatever your core count.
3. **Local DuckDB tables are TEMP only.** Without MotherDuck, `CREATE TABLE ... USING duckdb`
   [errors](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/src/pgduckdb_ddl.cpp#L1286-L1292).
4. **No mixed writes.** One transaction cannot write to both a Postgres table and a DuckDB
   table ([docs](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/docs/transactions.md)).
   The setting that allows it is called `unsafe_allow_mixed_transactions` for a reason.
5. **Every connection gets its own DuckDB**, with
   [4 GB and every core by default](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/docs/settings.md#L103-L118).
   Ten connections running reports at once can ask for 40 GB.
6. **You may not be able to install it on managed Postgres.** It needs
   `shared_preload_libraries`, and by default
   [only superusers](https://github.com/duckdb/pg_duckdb/blob/a9457c9cb3b7f2a8d189bbe017f3488ef4294a1d/docs/settings.md#L25-L30)
   can use DuckDB execution.

## What this benchmark is not

1. Fake, evenly spread data. Real tables have wider rows, skew and NULLs.
2. A warm cache on a fast laptop SSD. Cold reads from cloud disks will look different.
3. One machine, one run of 3 per cell. Treat differences under ~10% as noise.
4. Single user. No concurrent load on Postgres while the reports run.

## Files

| Path | What |
|---|---|
| [run.sh](run.sh) | One command: start the container, load data, run everything, save results |
| [bench.sh](bench.sh) | The timed queries (bash 3.2 safe, so it runs on stock macOS) |
| [hardware.sh](hardware.sh) | Prints machine and Docker specs |
| [sql/setup.sql](sql/setup.sql) | Builds the tables |
| [sql/parquet.sql](sql/parquet.sql) | Writes 50M rows to Parquet and times `read_parquet()` |
| [sql/numeric-gotcha.sql](sql/numeric-gotcha.sql) | Shows the plain `numeric` fallback |
| [results/](results/) | One folder per machine and date |

## License

MIT. Built with [Claude Code](https://claude.com/claude-code).
