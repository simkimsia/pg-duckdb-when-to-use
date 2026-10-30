-- Fake "orders" data at three sizes, plus a 1M-row customers table to join against.
-- amount is numeric(10,2) on purpose: plain `numeric` (no precision) makes
-- pg_duckdb give up and fall back to Postgres. See sql/numeric-gotcha.sql.
\timing on

DROP TABLE IF EXISTS customers, orders_1m, orders_10m, orders_50m;

CREATE TABLE customers AS
SELECT g AS id, 'region_' || (g % 20) AS region
FROM generate_series(1, 1000000) g;
ALTER TABLE customers ADD PRIMARY KEY (id);

CREATE TABLE orders_50m AS
SELECT g AS id,
       (random() * 999999)::int + 1 AS customer_id,
       (random() * 9999)::int AS product_id,
       date '2020-01-01' + (random() * 2000)::int AS order_date,
       round((random() * 500)::numeric, 2)::numeric(10,2) AS amount,
       (array['paid', 'refunded', 'pending'])[1 + (random() * 2)::int] AS status
FROM generate_series(1, 50000000) g;

CREATE TABLE orders_10m AS SELECT * FROM orders_50m WHERE id <= 10000000;
CREATE TABLE orders_1m  AS SELECT * FROM orders_50m WHERE id <= 1000000;

VACUUM ANALYZE;

SELECT relname AS table_name, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE relname IN ('customers', 'orders_1m', 'orders_10m', 'orders_50m')
ORDER BY 1;
