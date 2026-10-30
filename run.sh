#!/usr/bin/env bash
# One command: start Postgres 18 + pg_duckdb, load the data, run every benchmark,
# write results/<hostname>-<date>/. Needs Docker and ~10 GB free disk. Takes ~15-20 min.
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="${CONTAINER:-pgduck-bench}"
IMAGE="pgduckdb/pgduckdb:18-v1.1.1"
OUT="results/$(hostname -s)-$(date +%Y-%m-%d)"
mkdir -p "$OUT"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=duckdb --shm-size=4g "$IMAGE" \
    -c shared_buffers=4GB -c work_mem=256MB -c max_parallel_workers_per_gather=4
  until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
fi

./hardware.sh > "$OUT/hardware.txt"
docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 < sql/setup.sql | tee "$OUT/setup.txt"
docker exec -i "$CONTAINER" psql -U postgres < sql/numeric-gotcha.sql > "$OUT/numeric-gotcha.txt" 2>&1 || true
CONTAINER="$CONTAINER" ./bench.sh | tee "$OUT/results.csv"
docker exec -i "$CONTAINER" psql -U postgres -qAt < sql/parquet.sql 2>&1 | grep -E 'Time|ERROR|WARN' | tee "$OUT/parquet.txt"

echo "Done. Results in $OUT. Remove the container with: docker rm -f $CONTAINER"
