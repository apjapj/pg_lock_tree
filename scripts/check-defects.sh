#!/usr/bin/env bash
# check-defects.sh <postgres major version>: re-inject each recorded defect into the release script
# and require the test that first caught it to fail again.
#
# A bug fixed today can be reintroduced tomorrow, and nothing notices unless something puts it
# back. Each defects/<id>.patch reverts one fix; its .meta names the test that must fail while the
# patch is applied. This reports the regression rate: of the defects the suite once caught, how many
# does it still catch.
#
# pg_lock_tree does not install an extension: ci/job.sh loads the release script straight into a
# server with @extschema@ rewritten to public. So a cell is two fresh servers, not two file swaps:
# one with the pristine script (the control, which must pass) and one with the patched script (which
# must fail). A fresh server each time is what makes that work: the release script uses plain
# CREATE, not CREATE OR REPLACE, so it cannot be loaded twice into the same server.
#
# The three verdicts: caught, missed, could-not-run. A cell that cannot run is reported and is never
# counted as caught.
set -uo pipefail
v=${1:?usage: check-defects.sh <postgres major version>}
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
    echo "check-defects.sh: the docker CLI is not on PATH" >&2; exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "check-defects.sh: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
    exit 1
fi

num=${v//[^0-9]/}; port=55$num; container=pg-lock-tree-ci
rel="pg_lock_tree--$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" pg_lock_tree.control).sql"
[ -f "$rel" ] || { echo "no release script $rel; the control file names a version with no file" >&2; exit 1; }

export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres

# load <script>: the load ci/job.sh does, @extschema@ rewritten to public.
load_into() {
    { echo 'SET check_function_bodies = off;'
      sed -e '/^\\echo Use/d' -e 's/@extschema@/public/g' "$1"
    } | docker exec -i -e PGPASSWORD=test "$container" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres
}

# run_with <script> <test>: a fresh server, the script loaded, the test run. OUT holds the output,
# the return status is the test's. 3 means the server or the load failed, not the test.
OUT=""
run_with() {
    ./ci/server.sh up "$v" "$port" >/dev/null 2>&1 || return 3
    if ! load_into "$1"; then ./ci/server.sh down >/dev/null 2>&1; return 3; fi
    OUT=$(pg_prove --dbname postgres "$2" 2>&1); local rc=$?
    ./ci/server.sh down >/dev/null 2>&1
    return $rc
}

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
    if run_with "$tmp/$(basename "$rel")" "$test"; then
        echo "  $id: MISSED (the defect does not make $test fail)"
        missed=$((missed+1)); regressed="$regressed $id"
    elif printf '%s' "$OUT" | grep -qE 'Failed [0-9]+/[0-9]+ subtests'; then
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
echo "defects: $caught of $den caught, $missed missed, $norun could-not-run"
[ "$missed" -eq 0 ] || { echo "regression:$regressed" >&2; exit 1; }
exit 0
