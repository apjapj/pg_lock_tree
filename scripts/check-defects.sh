#!/usr/bin/env bash
# check-defects.sh [--local|--container] [<postgres major version>]: re-inject each recorded defect
# into the release script and require the test that first caught it to fail again.
#
# A bug fixed today can be reintroduced tomorrow, and nothing notices unless something puts it back.
# Each defects/<id>.patch reverts one fix; its .meta names the test that must fail while the patch is
# applied. This reports the regression rate: of the defects the suite once caught, how many does it
# still catch.
#
# pg_lock_tree does not install an extension: ci/job.sh loads the release script straight into a
# server with @extschema@ rewritten to public. So a cell is the pristine script and the patched one,
# each in a FRESH state, because the script uses plain CREATE and cannot be loaded twice. Two modes:
#
#   --container  build ci/Dockerfile and start a throwaway server per run (ci/server.sh); needs Docker.
#   --local      use the server already here. The Forgejo runner is itself a PostgreSQL and has no
#                Docker. A fresh state is a scratch DATABASE per run, created and dropped around the
#                load; the settings lock_tree needs (max_prepared_transactions, the pg_cron preload)
#                are server-level and a scratch database inherits them.
# Auto (the default) chooses container when the docker CLI and daemon are there, else local.
#
# The scratch database, and why it is careful:
#   * a UNIQUE name per run, so a database a killed run left behind cannot collide with the next;
#   * a trap that drops it, so a failure mid-run does not leave it;
#   * DROP DATABASE ... WITH (FORCE), so a leftover connection cannot block the drop;
#   * the catching test creates no cluster-wide object (no role, no tablespace), which is what makes
#     dropping the database complete: a cluster-wide leftover would survive DROP DATABASE. If a test
#     ever needs one, drop it here too, and if it needs pg_cron, that can only live in the database
#     named by cron.database_name (default postgres) and the run has to account for it.
#
# The three verdicts: caught, missed, could-not-run. A cell that cannot run is reported and is never
# counted as caught.
set -uo pipefail

mode=auto
case "${1:-}" in
    --local)     mode=local; shift ;;
    --container) mode=container; shift ;;
esac
v=${1:-}
cd "$(dirname "$0")/.."

if [ "$mode" = auto ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then mode=container; else mode=local; fi
fi
case "$mode" in
    container) [ -n "$v" ] || { echo "usage: check-defects.sh [--local|--container] <postgres major version>" >&2; exit 2; } ;;
esac

rel="pg_lock_tree--$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" pg_lock_tree.control).sql"
[ -f "$rel" ] || { echo "no release script $rel; the control file names a version with no file" >&2; exit 1; }

num=${v//[^0-9]/}; port=55$num; container=pg-lock-tree-ci
OUT=""
SCRATCH=""
RUNN=0

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER
# Container mode starts its own server on $port and needs the password; local mode uses the ambient
# server, whose environment the job already sets.
if [ "$mode" = container ]; then
    export PGPORT="$port" PGPASSWORD=test PGDATABASE=postgres
fi

# load_into <script> [database]: the load ci/job.sh does, @extschema@ rewritten to public. In local
# mode the target is the scratch database; in container mode it is the container's postgres.
load_into() {
    local script=$1 db=${2:-postgres}
    if [ "$mode" = container ]; then
        { echo 'SET check_function_bodies = off;'
          sed -e '/^\\echo Use/d' -e 's/@extschema@/public/g' "$script"
        } | docker exec -i -e PGPASSWORD=test "$container" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres
    else
        { echo 'SET check_function_bodies = off;'
          sed -e '/^\\echo Use/d' -e 's/@extschema@/public/g' "$script"
        } | psql -X -q -v ON_ERROR_STOP=1 -d "$db"
    fi
}

drop_scratch() {
    [ -n "$SCRATCH" ] || return 0
    psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"$SCRATCH\" WITH (FORCE)" >/dev/null 2>&1
    SCRATCH=""
}

# run_with <script> <test>: a fresh state with the script loaded, the test run. OUT holds the output,
# the return status is the test's. 3 means the server or the load failed, not the test.
run_with() {
    local script=$1 test=$2 rc
    if [ "$mode" = container ]; then
        ./ci/server.sh up "$v" "$port" >/dev/null 2>&1 || return 3
        if ! load_into "$script"; then ./ci/server.sh down >/dev/null 2>&1; return 3; fi
        OUT=$(pg_prove --dbname postgres "$test" 2>&1); rc=$?
        ./ci/server.sh down >/dev/null 2>&1
        return $rc
    else
        RUNN=$((RUNN + 1))
        SCRATCH="lt_defect_$(date +%s)_$$_$RUNN"
        psql -X -q -d postgres -c "CREATE DATABASE \"$SCRATCH\"" >/dev/null 2>&1 || { SCRATCH=""; return 3; }
        if ! load_into "$script" "$SCRATCH"; then drop_scratch; return 3; fi
        OUT=$(pg_prove --dbname "$SCRATCH" "$test" 2>&1); rc=$?
        drop_scratch
        return $rc
    fi
}

# A failure anywhere drops the scratch database; a killed job is covered by the unique name.
trap 'drop_scratch' EXIT INT TERM

total=0; caught=0; missed=0; norun=0; regressed=""
for patch in defects/*.patch; do
    [ -e "$patch" ] || continue
    id=$(basename "$patch" .patch)
    meta="defects/$id.meta"
    test=$(sed -n 's/^test=//p' "$meta" 2>/dev/null | head -1)
    if [ -z "$test" ]; then
        echo "  $id: COULD-NOT-RUN (no test= in $meta)"
        total=$((total+1)); norun=$((norun+1)); continue
    fi
    total=$((total+1))

    # Control: the pristine script must pass the test, or "caught" means nothing.
    if ! run_with "$rel" "$test"; then
        echo "  $id: COULD-NOT-RUN (the control failed: $test does not pass on the clean script)"
        printf '%s\n' "$OUT" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1)); continue
    fi

    tmp=$(mktemp -d)
    cp "$rel" "$tmp/$rel"
    if ! patch -s -p1 -d "$tmp" < "$patch"; then
        echo "  $id: COULD-NOT-RUN (the patch does not apply)"
        norun=$((norun+1)); rm -rf "$tmp"; continue
    fi
    if run_with "$tmp/$rel" "$test"; then
        echo "  $id: MISSED (the defect does not make $test fail)"
        missed=$((missed+1)); regressed="$regressed $id"
    elif printf '%s' "$OUT" | grep -qE 'Failed [0-9]+/[0-9]+'; then
        echo "  $id: caught (the defect makes $test fail)"
        caught=$((caught+1))
    else
        echo "  $id: COULD-NOT-RUN ($test did not report a failing assertion)"
        printf '%s\n' "$OUT" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1))
    fi
    rm -rf "$tmp"
done

den=$((caught+missed))
echo
echo "defects ($mode): $caught of $den caught, $missed missed, $norun could-not-run"
[ "$missed" -eq 0 ] || { echo "regression:$regressed" >&2; exit 1; }
exit 0
