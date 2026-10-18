#!/usr/bin/env bash
# ci/job.sh: the whole pgtap job, as one command.
#
# Usage:  ci/job.sh <postgres major version>
#
# Exists so a red run is reproducible with the command that produced it. A job spread across YAML
# steps is not, and the first real failure of this workflow is when that matters. pg_bloat_cause has
# the same split for the same reason.
#
# This does NOT run `make install`, and that is deliberate rather than an omission. The Forgejo pgtap
# job does not either: the runner image *is* a PostgreSQL, so `make install` there installs into the
# server the job then uses. On GitHub the server is a container and the runner is not PostgreSQL, so a
# host-side `make install` would install into whatever the runner happens to have, or fail outright.
# The release script is therefore loaded straight into the server, exactly as the Forgejo job does it,
# which is also the faster path and the one the suite has always been tested against.
#
# `make install` is covered by the install-path-checks job, which is where it belongs.
#
# Exit 0 = pgTAP passed on that version. 1 = it did not.
set -uo pipefail

v=${1:?usage: ci/job.sh <postgres major version>}
cd "$(dirname "$0")/.."

# Preflight. This job needs the docker CLI and a daemon that answers before it can start a server;
# a daemon that is not there fails later inside ci/server.sh as "failed to connect to the docker
# API", which names neither cause nor fix.
if ! command -v docker >/dev/null 2>&1; then
    echo "ci/job.sh: the docker CLI is not on PATH" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ci/job.sh: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
    echo "           start it, or point DOCKER_HOST at a reachable daemon; this job needs it" >&2
    exit 1
fi

# Numerically, not by concatenation: 55$19beta4 is 5519beta4, which docker rejects as a host port with
# an error that reads like a malformed number rather than a beta suffix. Stripping the non-digits gives
# 5519 for the tag 19beta4, which is what the port means.
num=${v//[^0-9]/}
port=55$num
container=pg-lock-tree-ci
fail=0
step() { printf '\n== %s\n' "$1"; }

step "server for $v on $port"
./ci/server.sh up "$v" "$port" || exit 1
trap './ci/server.sh down' EXIT

step "load the release script into public"
rel="pg_lock_tree--$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" pg_lock_tree.control).sql"
[ -f "$rel" ] || { echo "no release script $rel; the control file names a version with no file" >&2; exit 1; }
{ echo 'SET check_function_bodies = off;'
  sed -e '/^\\echo Use/d' -e 's/@extschema@/public/g' "$rel"
} | docker exec -i -e PGPASSWORD=test "$container" \
      psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres || exit 1

step "assert the server has THIS checkout's objects, not a stale load"
# NOT an extversion check, because loading the release script with @extschema@ rewritten to public
# does not create a pg_extension row at all. There is nothing to read a version from here, and asking
# for one produced a confusing empty result on the first run. What can be checked is that the objects
# this checkout defines exist, and that a doc example on them works.
n=$(docker exec -e PGPASSWORD=test "$container" \
      psql -X -tA -U postgres -d postgres \
      -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relname IN ('lock_tree','lock_tree_replay_samples')")
f=$(docker exec -e PGPASSWORD=test "$container" \
      psql -X -tA -U postgres -d postgres \
      -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname LIKE 'lock_tree%'")
echo "views present: ${n}/2   functions present: ${f}"
[ "$n" = 2 ] || { echo "the loaded release script did not create both views" >&2; exit 1; }
[ "${f:-0}" -ge 20 ] || { echo "only ${f} lock_tree_* functions; the release script defines 30" >&2; exit 1; }

# pg_prove runs on the runner and talks to the container over the mapped port. libpq must point at
# it, or every file fails on connect rather than on anything it is testing.
export PGHOST=127.0.0.1 PGPORT="$port" PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres

step "pgTAP"
pg_prove --dbname postgres test/*.sql || fail=1


step "docker footprint"
# The smoke alarm for the anonymous-volume leak the removal paths fix at source: a host that
# accumulates dangling volumes fails here rather than filling its disk. Deletes nothing.
scripts/docker-guard.sh check || fail=1

printf '\n== pg_lock_tree %s on PostgreSQL %s: %s\n' \
  "$(git rev-parse --short HEAD)" "$v" "$([ $fail -eq 0 ] && echo PASS || echo FAIL)"


exit $fail