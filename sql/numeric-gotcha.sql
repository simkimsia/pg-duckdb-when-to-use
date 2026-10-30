-- Plain `numeric` (no precision) vs numeric(10,2).
-- With force_execution on, the first SELECT prints a WARNING and quietly runs in Postgres.
CREATE TEMP TABLE gotcha_plain AS SELECT round((random() * 500)::numeric, 2) AS amount FROM generate_series(1, 1000);
CREATE TEMP TABLE gotcha_fixed AS SELECT amount::numeric(10,2) AS amount FROM gotcha_plain;

SET duckdb.force_execution = true;
SELECT sum(amount) FROM gotcha_plain;   -- WARNING ... DuckDB requires the precision of a NUMERIC to be set
SELECT sum(amount) FROM gotcha_fixed;   -- runs in DuckDB, no warning
