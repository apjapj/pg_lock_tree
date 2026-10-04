#!/usr/bin/env bash
# scenarios/run.sh — build each scenario, then query the same incident two ways and capture
# both outputs.
#
#   ./scenarios/run.sh            run all seven
#   ./scenarios/run.sh s6 s7      run named scenarios only
#
# Comparison is against the published recursive pg_blocking_pids() CTE, inlined in
# 01_standard_query.sql. Output lands in scenarios/out/, one file per scenario.
#
# Needs a superuser connection and the dblink contrib module:
#   PGHOST=127.0.0.1 PGUSER=postgres ./scenarios/run.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT="$HERE/out"
DATABASE=${PGDATABASE:-postgres}
: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER PGDATABASE

if ! psql -X -q -d "$DATABASE" -c 'SELECT 1' >/dev/null 2>&1; then
    cat >&2 <<EOF
error: cannot connect to $DATABASE as $PGUSER via $PGHOST.

  These scenarios need a superuser (they terminate backends and use dblink). Examples:

  locally, with peer auth:  sudo -u postgres ./scenarios/run.sh
  against the matrix:       EXT_SRC=\$PWD ./scripts/matrix.sh, then
                            PGHOST=127.0.0.1 PGPASSWORD=test ./scenarios/run.sh
EOF
    exit 2
fi

if ! psql -X -q -d "$DATABASE" -tAc "SELECT 1 FROM pg_extension WHERE extname='dblink'" | grep -q 1; then
    echo "creating dblink" >&2
    psql -X -q -d "$DATABASE" -c 'CREATE EXTENSION IF NOT EXISTS dblink' || exit 2
fi

if ! psql -X -q -d "$DATABASE" -tAc \
        "SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree'" | grep -q 1; then
    echo "error: pg_lock_tree is not installed in $DATABASE. Run 'make install' first." >&2
    exit 2
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.txt

ALL="s1_nightly_batch s2_three_chains s3_row_locks s4_wide_queue s5_mixed_locks s6_deadlock s7_prepared"
WANTED=${*:-$ALL}

for s in $WANTED; do
    case $s in
        s1_nightly_batch) title="one culprit, four waiters — the reference case" ;;
        s2_three_chains)   title="three unrelated incidents at once" ;;
        s3_row_locks)      title="row-lock contention: no relation in pg_locks" ;;
        s4_wide_queue)     title="60 sessions behind one idle transaction" ;;
        s5_mixed_locks)    title="advisory locks: waits with no relation" ;;
        s6_deadlock)       title="a cycle, which is not a queue" ;;
        s7_prepared)       title="a blocker that is not a session" ;;
        *) echo "unknown scenario: $s" >&2; exit 2 ;;
    esac

    printf '  %-18s %s\n' "$s" "$title"
    # -v ON_ERROR_STOP=1 would abort the file on the deliberate statement_timeout in the
    # published query, which is part of what we are demonstrating.
    if ! (cd "$HERE" && psql -X -q -d "$DATABASE" -f "$s.sql" >"$OUT/$s.txt" 2>&1); then
        echo "    !! psql exited non-zero — see $OUT/$s.txt" >&2
    fi
done

echo
printf '  %-18s %8s %8s %8s   %s\n' scenario waiting std  tree  verdict
for s in $WANTED; do
    f="$OUT/$s.txt"
    [ -f "$f" ] || continue
    cov=$(grep -A5 'actually_waiting' "$f" \
          | awk -F'|' '/^\| *[0-9]/{gsub(/ /,"",$2);gsub(/ /,"",$3);gsub(/ /,"",$4);print $2" "$3" "$4; exit}')
    set -- $cov
    w=${1:-?}; std=${2:-?}; tree=${3:-?}
    # guard the arithmetic: a scenario whose coverage block did not print leaves '?', and
    # $(( )) on a non-number is a syntax error that kills the whole summary
    case ${std}${tree} in
        *[!0-9]*) verdict="no coverage block" ;;
        *)
            if [ "$std" = "$tree" ]; then verdict="tie"
            elif [ "$tree" -gt "$std" ]; then verdict="pg_lock_tree +$((tree-std))"
            else verdict="published CTE +$((std-tree))"; fi ;;
    esac
    printf '  %-18s %8s %8s %8s   %s\n' "$s" "$w" "$std" "$tree" "$verdict"
done

echo
echo "  captured in $OUT"
echo
echo "  Read scenarios/README.md for what the numbers do and do not say."