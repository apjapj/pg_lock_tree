#!/usr/bin/env bash
# check-defects.sh [--local|--container] [<postgres major version>]: re-inject each recorded defect
# into the release script and require the check that first caught it to fail again.
#
# A bug fixed today can be reintroduced tomorrow, and nothing notices unless something puts it back.
# Each defects/<id>.patch reverts one fix; its .meta names the catcher that must fail while the patch
# is applied - a pgTAP file (test=) or, for a defect no pgTAP file can see, a command (command=)
# whose non-zero exit is the verdict, run with the scratch database as PGDATABASE. A command cell may
# name could_not_run_exit_codes=, codes that mean it did not run, so a setup failure reads as
# could-not-run and never as a catch. This reports the regression rate: of the defects the suite once
# caught, how many does it still catch.
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

# The one table of exit codes. check-defects.sh reads it to check that a command cell's
# could_not_run_exit_codes names a code the script it runs actually uses (scripts/exit-codes.sh).
. scripts/exit-codes.sh

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

# run_with <script> <catcher>: a fresh state with the script loaded, then the cell's catcher run -
# a pgTAP file via pg_prove, or a command, per KIND. OUT holds the output, the return status is the
# catcher's. 3 means it could not run: the server or the load failed, or a command exited with a
# code the cell declared as "did not run".
run_with() {
    local script=$1 catcher=$2 rc
    if [ "$mode" = container ]; then
        ./ci/server.sh up "$v" "$port" >/dev/null 2>&1 || return 3
        if ! load_into "$script"; then ./ci/server.sh down >/dev/null 2>&1; return 3; fi
        if [ "$KIND" = command ]; then
            OUT=$(PGDATABASE=postgres bash -c "$catcher" 2>&1); rc=$?
        else
            OUT=$(pg_prove --dbname postgres "$catcher" 2>&1); rc=$?
        fi
        ./ci/server.sh down >/dev/null 2>&1
    else
        RUNN=$((RUNN + 1))
        SCRATCH="lt_defect_$(date +%s)_$$_$RUNN"
        psql -X -q -d postgres -c "CREATE DATABASE \"$SCRATCH\"" >/dev/null 2>&1 || { SCRATCH=""; return 3; }
        if ! load_into "$script" "$SCRATCH"; then drop_scratch; return 3; fi
        if [ "$KIND" = command ]; then
            OUT=$(PGDATABASE="$SCRATCH" bash -c "$catcher" 2>&1); rc=$?
        else
            OUT=$(pg_prove --dbname "$SCRATCH" "$catcher" 2>&1); rc=$?
        fi
        drop_scratch
    fi
    # A command cell may name exit codes that mean it did not run - a setup failure, say - so a
    # catch is never credited to one. The same guard the patch-defect schema uses, in the shell:
    # only a catcher that ran to completion and reported a real failure is a catch.
    if [ "$KIND" = command ] && [ "$rc" -ne 0 ]; then
        local c
        for c in $NOT_RUN; do [ "$rc" -eq "$c" ] && return 3; done
    fi
    return $rc
}

# A failure anywhere drops the scratch database; a killed job is covered by the unique name.
trap 'drop_scratch' EXIT INT TERM

total=0; caught=0; missed=0; norun=0; regressed=""
for patch in defects/*.patch; do
    [ -e "$patch" ] || continue
    id=$(basename "$patch" .patch)
    meta="defects/$id.meta"
    test=$(sed -n 's/^test=//p' "$meta" 2>/dev/null | head -1)
    command=$(sed -n 's/^command=//p' "$meta" 2>/dev/null | head -1)
    NOT_RUN=$(sed -n 's/^could_not_run_exit_codes=//p' "$meta" 2>/dev/null | head -1)
    total=$((total+1))

    # A cell names its catcher one of two ways: test=, a pgTAP file, or command=, a program whose
    # exit status is the verdict. Both are run against a fresh state with the script loaded.
    if [ -n "$test" ] && [ -n "$command" ]; then
        echo "  $id: COULD-NOT-RUN ($meta names both test= and command=)"
        norun=$((norun+1)); continue
    elif [ -n "$command" ]; then
        KIND=command; catcher=$command; subject="the command"
    elif [ -n "$test" ]; then
        KIND=test; catcher=$test; subject="$test"
    else
        echo "  $id: COULD-NOT-RUN (no test= or command= in $meta)"
        norun=$((norun+1)); continue
    fi

    # A command cell's could_not_run_exit_codes must name codes the one table declares
    # (scripts/exit-codes.sh). A number that means nothing would simply never match, and a setup
    # failure would then read as a real failure and be credited as a catch - the exact hole the
    # codes exist to close - so a code outside the table is a malformed cell, reported, not run.
    if [ "$KIND" = command ] && [ -n "$NOT_RUN" ]; then
        for c in $NOT_RUN; do
            case " $EXIT_COULD_NOT_RUN_CODES " in
                *" $c "*) ;;
                *) echo "  $id: COULD-NOT-RUN ($meta declares could_not_run_exit_codes=$c, which scripts/exit-codes.sh does not)"
                   norun=$((norun+1)); continue 2 ;;
            esac
        done
    fi

    # Control: the catcher must pass on the pristine script, or "caught" means nothing.
    if ! run_with "$rel" "$catcher"; then
        echo "  $id: COULD-NOT-RUN ($subject does not pass on the clean script)"
        printf '%s\n' "$OUT" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1)); continue
    fi

    tmp=$(mktemp -d)
    cp "$rel" "$tmp/$rel"
    if ! patch -s -p1 -d "$tmp" < "$patch"; then
        echo "  $id: COULD-NOT-RUN (the patch does not apply)"
        norun=$((norun+1)); rm -rf "$tmp"; continue
    fi
    run_with "$tmp/$rel" "$catcher"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  $id: MISSED (the defect does not make $subject fail)"
        missed=$((missed+1)); regressed="$regressed $id"
    elif [ "$rc" -eq 3 ]; then
        # The catcher declared this code as "did not run", or the server or the load failed. Either
        # way nothing was measured, so it is not a catch.
        echo "  $id: COULD-NOT-RUN ($subject could not run on the patched script)"
        printf '%s\n' "$OUT" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1))
    elif [ "$KIND" = command ]; then
        # Non-zero, and not a code the cell declared as "did not run": the command ran and failed.
        echo "  $id: caught (the defect makes $subject fail)"
        caught=$((caught+1))
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
echo "defects ($mode): $total cell(s), $den ran: $caught caught, $missed missed; $norun could not run"
[ "$missed" -eq 0 ] || { echo "regression:$regressed" >&2; exit 1; }
exit 0
