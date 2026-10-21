#!/usr/bin/env bash
# bench-overhead.sh: what one call to the read side costs, beside a hand-written baseline.
#
# Why this exists. "lock_tree_text() is a millisecond" is a claim with no fixture under it, and the
# optional overhead tile in the book wants a number a reader can reproduce. This script states the
# fixture, takes the median of N calls, and prints the same measurement for the hand-written query an
# operator would otherwise paste, so the overhead of the extension is visible rather than asserted.
#
# What is measured. `SELECT count(*) FROM lock_tree_text()` and `... lock_tree_roots()`, run from
# psql with `\timing on`. That is parse, plan, execute and the round trip: a SQL function has no plan
# cache across separate statements, so this is what a person running the command in psql pays. The
# count(*) keeps the number of rows the client transfers constant as the queue grows. The median is
# the warm steady state: the FIRST call in a fresh backend pays for cold catalog caches and is several
# times slower (19 to 28 ms for lock_tree_roots() on PG 18.6 against 5 to 8 ms warm), and a median over
# 30 samples deliberately does not report it.
#
# The baseline is `pg_blocking_pids()`, the built-in an operator reaches for when they do not have
# this extension: one row per blocked session, and one per (blocked, blocker) pair for the roots. It
# answers a smaller question than the extension (no root object, no depth, no suggested action), so it
# is a floor, not an equal, and it is labelled as such.
#
# The fixture. One session holds ACCESS EXCLUSIVE on `lock_tree_bench_fixture`; N sessions are
# blocked on `SELECT count(*) FROM lock_tree_bench_fixture`. N = 0 is the idle tree, with no fixture
# sessions at all. The waiter count needs `max_connections` of at least N+3; a count that does not fit
# is reported as skipped, never silently dropped.
#
# Usage:
#   ./scripts/bench-overhead.sh                          # waiters 0,10,50,150, median of 30
#   ./scripts/bench-overhead.sh --waiters=0,10 --repeat=10
#   ./scripts/bench-overhead.sh --keep                   # leave the fixture table behind
#   ./scripts/bench-overhead.sh --force                  # required: it opens sessions and a table
#
# It creates and drops its own table and its own sessions, so it is safe on a scratch database. It
# needs a superuser: it terminates the sessions it started, by application_name and by name only.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGUSER PGDATABASE

waiters_list="0,10,50,150"
repeat=30
hold=600
keep=0
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --waiters=*) waiters_list="${1#*=}" ;;
        --repeat=*)  repeat="${1#*=}" ;;
        --hold=*)    hold="${1#*=}" ;;
        --keep)      keep=1 ;;
        --force)     force=1 ;;
        -h|--help)   sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$force" -ne 1 ]; then
    cat >&2 <<'MSG'
  This script opens a blocker session and N blocked sessions, and creates a table, in the database
  named by PGDATABASE. It terminates only the sessions it started (by application_name).

  Run it against a scratch database, or pass --force to confirm you mean it.
MSG
    exit 2
fi

q() { psql -X -tA -c "$1" 2>/dev/null; }

if [ "$(q "SELECT count(*) FROM pg_extension WHERE extname='pg_lock_tree'")" != 1 ]; then
    echo "  pg_lock_tree is not installed in $PGDATABASE on $PGHOST:$PGPORT" >&2
    exit 1
fi

version=$(q "SELECT current_setting('server_version')")
maxconn=$(q "SHOW max_connections")

printf '\n  \033[1mpg_lock_tree read-overhead benchmark\033[0m\n'
printf '  server %s on %s, database %s, max_connections %s, median of %s calls\n' \
       "$version" "$PGHOST" "$PGDATABASE" "$maxconn" "$repeat"
printf '  fixture: one blocker holding ACCESS EXCLUSIVE on lock_tree_bench_fixture, N sessions blocked on a SELECT from it\n\n'

q "CREATE TABLE IF NOT EXISTS lock_tree_bench_fixture(id int)" >/dev/null
q "INSERT INTO lock_tree_bench_fixture VALUES (1)" >/dev/null

blocker_pid=""
waiter_pids=""

start_fixture() {
    n=$1
    [ "$n" -eq 0 ] && return 0
    PGAPPNAME=lock_tree_bench_blocker psql -X -q \
        -c "BEGIN; LOCK TABLE lock_tree_bench_fixture IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep($hold);" \
        >/dev/null 2>&1 &
    blocker_pid=$!
    # The blocker must hold the lock before a waiter can block on it.
    for _ in $(seq 1 100); do
        held=$(q "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
                  WHERE a.application_name='lock_tree_bench_blocker'
                    AND l.mode='AccessExclusiveLock' AND l.granted")
        [ "${held:-0}" -ge 1 ] && break
        sleep 0.1
    done
    for _ in $(seq 1 "$n"); do
        PGAPPNAME=lock_tree_bench_waiter psql -X -q \
            -c "SELECT count(*) FROM lock_tree_bench_fixture;" >/dev/null 2>&1 &
        waiter_pids="$waiter_pids $!"
    done
    # And every waiter must actually be waiting before anything is timed.
    for _ in $(seq 1 300); do
        blocked=$(q "SELECT count(*) FROM pg_stat_activity
                     WHERE application_name='lock_tree_bench_waiter' AND wait_event_type='Lock'")
        [ "${blocked:-0}" -ge "$n" ] && return 0
        sleep 0.1
    done
    echo "  the $n waiters did not all block within 30 s; refusing to time" >&2
    return 1
}

stop_fixture() {
    q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
       WHERE application_name IN ('lock_tree_bench_blocker','lock_tree_bench_waiter')" >/dev/null
    [ -n "$blocker_pid" ] && wait "$blocker_pid" 2>/dev/null
    for p in $waiter_pids; do wait "$p" 2>/dev/null; done
    blocker_pid=""; waiter_pids=""
}

median_ms() {
    sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) { print "?"; exit }
            if (NR % 2) { printf "%.2f", a[(NR+1)/2] }
            else        { printf "%.2f", (a[NR/2] + a[NR/2+1]) / 2 }
        }'
}

# One psql session per query, so nothing is cached between the extension and the baseline in a way the
# reader did not ask for, and \timing rather than EXPLAIN ANALYZE because the tile's number is the
# one a person sees at the prompt.
time_sql() {
    sql=${1%;}
    tmp=$(mktemp)
    { echo '\timing on'; for _ in $(seq 1 "$repeat"); do printf '%s;\n' "$sql"; done; } \
        | psql -X -A -t 2>/dev/null \
        | grep '^Time:' | sed 's/^Time: //; s/ ms$//' > "$tmp"
    # The first version echoed the SQL without a semicolon. psql then read all N lines as one
    # statement, printed one "Time:", and the "median of 30" was the median of one sample: 0.43 ms
    # for a call that costs 5 to 8 ms. A sample count that is not the requested count is a broken
    # measurement, and this script refuses to print it rather than average it.
    n=$(wc -l < "$tmp")
    if [ "$n" -ne "$repeat" ]; then
        printf '  expected %s timings, got %s; refusing to report a median from them\n' \
               "$repeat" "$n" >&2
        rm -f "$tmp"
        return 1
    fi
    median_ms < "$tmp"
    rm -f "$tmp"
}

printf '  %-8s %-22s %-24s %-22s %s\n' \
       'waiters' 'lock_tree_text()' 'baseline: pg_blocking_pids' 'lock_tree_roots()' 'baseline: unnest'
printf '  %s\n' '--------------------------------------------------------------------------------------------------'

for n in ${waiters_list//,/ }; do
    if [ $((n + 3)) -gt "$maxconn" ]; then
        printf '  %-8s skipped: %s waiters need max_connections >= %s, and this server has %s\n' \
               "$n" "$n" "$((n + 3))" "$maxconn"
        continue
    fi
    if ! start_fixture "$n"; then
        stop_fixture
        continue
    fi
    if [ "$n" -gt 0 ]; then
        # A benchmark that does not check its own fixture is how a quiet tree gets timed and called a
        # result. One blocker means exactly one root, and it must carry every waiter.
        roots_rows=$(q "SELECT count(*) FROM lock_tree_roots()")
        root_waiters=$(q "SELECT coalesce(max(blocked_sessions), 0) FROM lock_tree_roots()")
        if [ "${roots_rows:-0}" -ne 1 ] || [ "${root_waiters:-0}" -ne "$n" ]; then
            printf '  %-8s fixture wrong: lock_tree_roots() returned %s row(s), max blocked_sessions %s, wanted 1 and %s\n' \
                   "$n" "${roots_rows:-?}" "${root_waiters:-?}" "$n" >&2
            stop_fixture
            continue
        fi
    fi
    if ! text=$(time_sql "SELECT count(*) FROM lock_tree_text()") \
       || ! btext=$(time_sql "SELECT count(*) FROM (SELECT pid FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0) q") \
       || ! roots=$(time_sql "SELECT count(*) FROM lock_tree_roots()") \
       || ! broots=$(time_sql "SELECT count(*) FROM (SELECT b FROM pg_stat_activity a, LATERAL unnest(pg_blocking_pids(a.pid)) b) q"); then
        stop_fixture
        exit 1
    fi
    stop_fixture
    printf '  %-8s %-22s %-24s %-22s %s\n' "$n" "$text" "$btext" "$roots" "$broots"
done

[ "$keep" -eq 1 ] || q "DROP TABLE IF EXISTS lock_tree_bench_fixture" >/dev/null
printf '\n  all times in milliseconds. %s\n\n' \
       "baseline answers a smaller question; see the header"
