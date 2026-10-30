-- Same 50M rows, written out as Parquet, then queried with read_parquet().
-- Each query runs twice, the second run is the one reported.
\timing on
COPY (SELECT * FROM orders_50m) TO '/tmp/orders_50m.parquet' (FORMAT parquet);
SET duckdb.force_execution = true;

SELECT r['order_date'], count(*), sum(r['amount'])
FROM read_parquet('/tmp/orders_50m.parquet') r GROUP BY 1 ORDER BY 1 LIMIT 1;
SELECT r['order_date'], count(*), sum(r['amount'])
FROM read_parquet('/tmp/orders_50m.parquet') r GROUP BY 1 ORDER BY 1 LIMIT 1;

SELECT r['customer_id'], count(*), count(DISTINCT r['product_id']), avg(r['amount'])
FROM read_parquet('/tmp/orders_50m.parquet') r GROUP BY 1 ORDER BY 4 DESC LIMIT 1;
SELECT r['customer_id'], count(*), count(DISTINCT r['product_id']), avg(r['amount'])
FROM read_parquet('/tmp/orders_50m.parquet') r GROUP BY 1 ORDER BY 4 DESC LIMIT 1;
