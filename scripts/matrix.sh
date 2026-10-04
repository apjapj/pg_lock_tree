#!/usr/bin/env bash
# scripts/matrix.sh: install pg_lock_tree into every test container and run the pgTAP suite.
# Needs: a compose file whose services mount "${EXT_SRC:-.}:/src:ro", and a Dockerfile.test that
# includes make + postgresql-server-dev-<version> (see dev environment setup v2.1).
# Usage: COMPOSE_FILE=../pg-dev-infra/docker-compose.test.yml scripts/matrix.sh
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f ${COMPOSE_FILE:-docker-compose.test.yml}"
export EXT_SRC="$PWD"          # mounted at /src in every test container
declare -A PORT=( [pg14]=5414 [pg15]=5415 [pg16]=5416 [pg17]=5417 [pg18]=5418 [pg19]=5419 )
SERVICES=${SERVICES:-"pg14 pg15 pg16 pg17 pg18 pg19"}
failed=()

$COMPOSE up -d --wait $SERVICES   # recreates containers if the /src mount changed

for s in $SERVICES; do
  echo "=== $s ==="
  for _ in $(seq 1 30); do
    pg_isready -q -h 127.0.0.1 -p "${PORT[$s]}" && break
    sleep 1
  done
  if ! $COMPOSE exec -T -u root "$s" sh -c 'rm -rf /tmp/build && cp -r /src /tmp/build && make -s -C /tmp/build install' \
     || ! PGHOST=127.0.0.1 PGPORT=${PORT[$s]} PGUSER=postgres PGPASSWORD=test \
          psql -qX -v ON_ERROR_STOP=1 -c 'DROP EXTENSION IF EXISTS pg_lock_tree; CREATE EXTENSION pg_lock_tree;' \
     || ! PGHOST=127.0.0.1 PGPORT=${PORT[$s]} PGUSER=postgres PGPASSWORD=test \
          pg_prove --dbname postgres test/*.sql; then
    failed+=("$s")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED on: ${failed[*]}"; exit 1
fi
echo "All versions passed: $SERVICES"
