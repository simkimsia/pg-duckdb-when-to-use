#!/usr/bin/env bash
# Times 4 query shapes x 3 table sizes x 3 engines. Each cell runs 3 times; the median is kept.
# Engines:
#   postgres      plain Postgres (force_execution off)
#   duckdb        pg_duckdb with default settings
#   duckdb-tuned  pg_duckdb with the Postgres scan widened to 8 threads / 4 workers
# Output: CSV on stdout. A non-zero "errors" column means a query failed or fell back.
# Written for bash 3.2 (the macOS default), so no associative arrays.
set -euo pipefail

CONTAINER="${CONTAINER:-pgduck-bench}"
SIZES="${SIZES:-1m 10m 50m}"

query_sql() {
  case "$1" in
    daily)        echo "SELECT order_date, count(*), sum(amount) FROM $2 GROUP BY order_date ORDER BY order_date" ;;
    per_customer) echo "SELECT customer_id, count(*), count(DISTINCT product_id), avg(amount) FROM $2 GROUP BY customer_id ORDER BY 4 DESC LIMIT 10" ;;
    join)         echo "SELECT c.region, o.status, count(*), sum(o.amount) FROM $2 o JOIN customers c ON c.id = o.customer_id GROUP BY 1, 2 ORDER BY 1, 2" ;;
    window)       echo "SELECT count(*) FROM (SELECT customer_id, amount, rank() OVER (PARTITION BY customer_id ORDER BY amount DESC) r FROM $2) s WHERE r = 1" ;;
  esac
}

engine_settings() {
  case "$1" in
    postgres)     echo "SET duckdb.force_execution = false;" ;;
    duckdb)       echo "SET duckdb.force_execution = true;" ;;
    duckdb-tuned) echo "SET duckdb.force_execution = true; SET duckdb.threads_for_postgres_scan = 8; SET duckdb.max_workers_per_postgres_scan = 4;" ;;
  esac
}

echo "rows,query,engine,median_ms,errors"
for size in $SIZES; do
  for q in daily per_customer join window; do
    sql=$(query_sql "$q" "orders_$size")
    for engine in postgres duckdb duckdb-tuned; do
      out=$(printf '%s\n\\timing on\n%s;\n%s;\n%s;\n' "$(engine_settings "$engine")" "$sql" "$sql" "$sql" \
        | docker exec -i "$CONTAINER" psql -U postgres -qAt 2>&1)
      errors=$(grep -cE 'WARNING|ERROR' <<<"$out" || true)
      median=$(grep -o 'Time: [0-9.]*' <<<"$out" | awk '{print $2}' | sort -n | sed -n 2p)
      echo "$size,$q,$engine,$median,$errors"
    done
  done
done
