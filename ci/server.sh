#!/usr/bin/env bash
#!/usr/bin/env bash
# ci/server.sh: start or stop one throwaway PostgreSQL for a CI job.
#
# Usage:  ci/server.sh up   <major> <port>
#         ci/server.sh down
#
# This exists because the two settings the suite needs cannot be set on a GitHub service container:
# GitHub has no `command:` override for services, so max_prepared_transactions and the pg_cron preload
# have to go in the server's own command line. Running the container here rather than declaring it as
# a service is what allows that.
#
# `up` does NOT stop the container on its way out. An earlier version trapped EXIT and removed it,
# which meant the container was gone before the caller had run a single test, and the failure looked
# like a missing image rather than a lifecycle mistake. The caller owns the teardown.
#
# Split out of the workflow for the same reason ci/job.sh exists: a red run has to be reproducible
# with one command, and a 90-line `run:` block in YAML is not one.
#
# The container name is fixed, because a job runs one at a time and a leftover from a cancelled job
# would otherwise make the next one fail on a name clash rather than on its own merits. `up` removes
# any stale one first for the same reason.
set -uo pipefail

cmd=${1:?usage: ci/server.sh up <major> <port> | down}
name=pg-lock-tree-ci

if [ "$cmd" = down ]; then
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    exit 0
fi

v=${2:?usage: ci/server.sh up <major> <port>}
port=${3:?usage: ci/server.sh up <major> <port>}
image="pg-lock-tree-ci:$v"

docker rm -f -v "$name" >/dev/null 2>&1 || true

printf '== build %s\n' "$image"
# 19rc1 is the image tag; the apt package inside it is postgresql-19. Passing the tag through as the
# apt version stops the matrix at its last version with "Unable to locate package", so strip any
# beta/rc suffix here rather than in the Dockerfile, where the reason would be less obvious.
apt=${v%%beta*}; apt=${apt%%rc*}
# WITH_MAKE=1 only for the install-path job, which runs `make install` inside the container. See
# ci/Dockerfile for why that cannot be done any other way.
withmake=0; [ "${4:-}" = make ] && withmake=1
docker build -q --build-arg PG_MAJOR="$v" --build-arg APT_MAJOR="$apt" \
            --build-arg WITH_MAKE="$withmake" -t "$image" ci/ >/dev/null || exit 1

printf '== start postgres %s on %s\n' "$v" "$port"
docker run -d --name "$name" \
  -e POSTGRES_PASSWORD=test \
  -p "127.0.0.1:$port:5432" \
  "$image" \
  postgres -c max_prepared_transactions=10 \
           -c shared_preload_libraries=pg_cron,pg_stat_statements \
  >/dev/null || exit 1

printf '== wait for it\n'
for i in $(seq 1 60); do
  if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  if [ "$i" = 60 ]; then
    echo "the server did not become ready; its log follows" >&2
    docker logs "$name" >&2 || true
    exit 1
  fi
  sleep 2
done

# Assert the two settings the suite depends on, rather than assuming the command line took. A server
# that started without them makes three pgTAP files skip themselves, which reads as a pass and is not
# one. pg_cron in particular stops the server outright if the module is missing, so getting here at
# all proves the image is right; the assertion is here so that a future change cannot quietly remove it.
docker exec "$name" psql -X -tA -U postgres -d postgres -c "SHOW max_prepared_transactions" \
  | grep -qx 10 || { echo "max_prepared_transactions is not 10" >&2; exit 1; }
docker exec "$name" psql -X -tA -U postgres -d postgres -c "SHOW shared_preload_libraries" \
  | grep -q pg_cron || { echo "pg_cron is not preloaded" >&2; exit 1; }

echo "server ready"