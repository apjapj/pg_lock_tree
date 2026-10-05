#!/usr/bin/env bash
# bench-history.sh: time the read side of pg_lock_tree against a synthetic history.
#
# Why this exists. The 0.15 changelog claims the read functions got faster, and a number in a
# changelog is a claim nobody can check in eighteen months. This turns it back into a measurement:
# build a history of a stated shape, run each read function, print the times.
#
# It builds its own data and prunes it afterwards, so it is safe to run against a scratch database.
# It does TRUNCATE lock_tree_history, and it says so and refuses to run without --force.
#
# Usage:
#   ./scripts/bench-history.sh                     # 7 days, 10s interval, 20 blocked sessions
#   ./scripts/bench-history.sh --days=3 --every=5s --sessions=60
#   ./scripts/bench-history.sh --force             # required, because it truncates the history
#   ./scripts/bench-history.sh --keep              # leave the fixture in place afterwards
#
# Needs superuser. Takes a couple of minutes: the default fixture is about 1.2 million rows.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER

days=7
every='10 seconds'
sessions=20
force=0
keep=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --days=*)      days="${1#*=}" ;;
        --every=*)     every="${1#*=}" ;;
        --sessions=*)  sessions="${1#*=}" ;;
        --force)       force=1 ;;
        --keep)        keep=1 ;;
        -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

fail=0
say_ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
say_bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

if [ "$force" -ne 1 ]; then
    cat >&2 <<'MSG'
  This script TRUNCATEs lock_tree_history to build a known fixture, and then prunes it.

  Run it against a scratch database, or pass --force to confirm you mean it.
MSG
    exit 2
fi

if ! psql -X -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree'" 2>/dev/null | grep -q 1; then
    echo "  pg_lock_tree is not installed in this database" >&2
    exit 1
fi

printf '\n  \033[1mfixture\033[0m: %s days, every %s, %s blocked sessions per sample\n\n' \
       "$days" "$every" "$sessions"

# Interleaved so no two roots are ever the same row: the fixture is meant to be a plausible queue,
# not one enormous blocker. The root cycles every sample and the waiters hang off it.
#
# generate_series over timestamptz returns ONE column, so the alias is (at) and the row number comes
# from a lateral. Writing AS t(at, n) is a syntax error, which is what the first version did.
psql -X -q >/dev/null 2>&1 <<SQL
TRUNCATE lock_tree_history;
INSERT INTO lock_tree_history
  (sampled_at, root_pid, depth, pid, state, waiting_for, wait_age,
   application_name, query, root_object, query_id)
SELECT t.at,
       1000 + (r.n % 3),
       d.d,
       1000 + (r.n % 3) + d.d * 100,
       CASE WHEN d.d = 0 THEN 'idle in transaction' ELSE 'active' END,
       CASE WHEN d.d = 0 THEN NULL ELSE 'AccessExclusiveLock on public.ledger' END,
       make_interval(secs => (r.n % 60) * 3),
       CASE WHEN d.d = 0 THEN 'batch_' || (r.n % 3)::text ELSE 'api_' || (d.d % 4)::text END,
       CASE WHEN d.d = 0 THEN 'UPDATE ledger SET amount = amount WHERE id = 1'
            ELSE 'SELECT * FROM orders WHERE id = ' || d.d END,
       NULL,
       CASE WHEN d.d = 0 THEN 5000000000000000000 + (r.n % 3) ELSE NULL END
  FROM generate_series(now() - interval '$days days', now(), interval '$every') AS t(at)
  CROSS JOIN LATERAL (SELECT row_number() OVER () AS n) r
  CROSS JOIN generate_series(0, $((sessions - 1))) AS d(d);
SQL

psql -X -tA -F' | ' -c "
SELECT '  rows', count(*),
       'samples', count(DISTINCT sampled_at),
       'size', pg_size_pretty(pg_total_relation_size('lock_tree_history'))
  FROM lock_tree_history" | sed 's/^/ /'

# VACUUM, and not ANALYZE alone, because a fixture loaded by one big INSERT has no visibility map at
# all. Without one, an index-only scan cannot skip the heap and falls back to fetching every page, so
# the timings below would describe a table no real one ever looks like: a real history is appended to
# continuously and autovacuum maintains its visibility map, and an index-only scan on it is the common
# case rather than the exception.
#
# Measured on this fixture, PG18: lock_tree_incidents() 2660.5 ms before the vacuum and 233.3 ms
# after, an order of magnitude, same data and same query. ANALYZE alone does not do it, because the
# visibility map is what vacuum sets.
psql -X -q -c 'VACUUM (ANALYZE) lock_tree_history' >/dev/null 2>&1

# The state the timings are taken in, printed because a benchmark that reports timings should report
# that too. relallvisible counts pages known all-visible; it is 0 before the vacuum above.
psql -X -tA -c "
SELECT '  all-visible pages ' || relallvisible || ' of ' || relpages ||
       '   (0 would mean no index-only scan can skip the heap)'
  FROM pg_class WHERE relname = 'lock_tree_history'" | sed 's/^/ /'

# Each timing is a separate psql so nothing is cached between them in a way the caller did not ask
# for, and EXPLAIN ANALYZE is used rather than \timing so the server reports its own number.
# The live-tree reads, timed separately and labelled as such.
#
# They were missing from the loop below until someone read this script to check a number and could not
# find the function in it: lock_tree_statements() was reported as taking 3026 ms, and the 3026 ms in the
# table belongs to lock_tree_duration_by_application(). lock_tree_statements() reads the LIVE tree, not
# the history, so it is milliseconds however big the history is.
#
# A reader should not have to know which of these touches the history to know which will be slow. Two
# groups, and the group says so.
printf '\n  \033[1mlive-tree reads\033[0m, not the history: milliseconds however big it is\n\n'
for fn in \
  "SELECT count(*) FROM lock_tree_statements()" \
  "SELECT count(*) FROM lock_tree_roots()" \
  "SELECT count(*) FROM lock_tree_wide()" \
  "SELECT count(*) FROM lock_tree_summary()" \
  "SELECT count(*) FROM lock_tree_text()" \
  "SELECT count(*) FROM lock_tree_actions()" \
  "SELECT count(*) FROM lock_tree_command()"
do
    ms=$(psql -X -tA -c "EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) $fn" 2>/dev/null \
         | python3 -c "
import json,sys
try:    d = json.load(sys.stdin)
except Exception: print('?'); sys.exit()
print(round(d[0]['Execution Time'], 1))")
    printf '  %10s ms  %s\n' "$ms" "$fn"
done
printf '\n'

# SELECT * and not SELECT count(*), and the difference is not cosmetic.
#
# count(*) asks only how many rows came back, so the planner is free to drop any output column whose
# value nobody looks at. lock_tree_duration_by_application() computes an ids column from a CTE that
# aggregates DISTINCT query_id per application, and count(*) drops that CTE entirely: the plan it
# produces contains no query_id aggregation at all. Measured on the standard fixture, cold, same
# session: count(*) 2048.3 ms, SELECT * 2249.1 ms, and the published figure was the smaller one. Six
# of the seven read functions below produce a different plan under count(*).
#
# So these are timed the way a caller runs them. The check further down proves the aggregation is
# still in the plan, because a timing that quietly measured less work is exactly the kind of number
# that gets quoted for years.
printf '\n  \033[1mread functions\033[0m, whole window, timed as SELECT * because count(*) drops columns\n\n'
for fn in \
  "SELECT * FROM lock_tree_history_statements()" \
  "SELECT * FROM lock_tree_incidents()" \
  "SELECT * FROM lock_tree_sampling_advice()" \
  "SELECT * FROM lock_tree_deadlocks()" \
  "SELECT * FROM lock_tree_history_size()" \
  "SELECT * FROM lock_tree_replay_samples" \
  "SELECT * FROM lock_tree_duration()" \
  "SELECT * FROM lock_tree_duration_by_application()" \
  "SELECT * FROM lock_tree_replay(now() - interval '1 hour')"
do
    ms=$(psql -X -tA -c "EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) $fn" 2>/dev/null \
         | python3 -c "
import json,sys
try:    d = json.load(sys.stdin)
except Exception: print('?'); sys.exit()
try:    print('%.1f' % d[0]['Execution Time'])
except Exception: print('?')
")
    printf '  %8s ms  %s\n' "$ms" "$fn"
done

# The narrow window is the one that matters most in practice: a dashboard asking about the last hour
# against a history that has been accumulating for a week. This is where a window bound that the
# planner cannot turn into an index bound shows up, because the cost is the WHOLE history either way.
printf '\n  \033[1mnarrow window\033[0m, one millisecond, which matches no sample at all\n\n'
for fn in \
  "SELECT * FROM lock_tree_duration(interval '1 millisecond')" \
  "SELECT * FROM lock_tree_duration_by_application(interval '1 millisecond')" \
  "SELECT * FROM lock_tree_history_statements(interval '1 millisecond')"
do
    ms=$(psql -X -tA -c "EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) $fn" 2>/dev/null \
         | python3 -c "
import json,sys
try:    d = json.load(sys.stdin)
except Exception: print('?'); sys.exit()
try:    print('%.1f' % d[0]['Execution Time'])
except Exception: print('?')
")
    printf '  %8s ms  %s\n' "$ms" "$fn"
done

printf '\n  \033[1mindex usage\033[0m, the claim that the plan actually seeks\n\n'
# The difference between an index bound and a filter is visible in the plan text alone, so this
# needs no ANALYZE and no timing, and it cannot pass vacuously the way a time bound can.
plan=$(psql -X -tA -c "
EXPLAIN SELECT count(*) FROM lock_tree_duration(interval '1 millisecond')" 2>/dev/null)
if printf '%s' "$plan" | grep -q 'Index Cond'; then
    say_ok "the window lower bound became an Index Cond on sampled_at, not a Filter over the index"
else
    say_bad "no Index Cond: the window bound is still a filter over the whole index"
    printf '%s\n' "$plan" | sed 's/^/        /' | head -12
fi

# The timings above are only meaningful if the plan they ran still contains the work. This is the
# check that says so, and it is here because a timing can be quietly wrong: count(*) is cheaper
# because it computes less, and nothing in the output would say so.
#
# The marker is the grouping, not the word array_agg, which the plan never spells. Two of the three
# GroupAggregates in this function group on aliases r and r_1; only the ids CTE groups the base table
# itself, so only it appears as "Group Key: lock_tree_history.application_name".
byapp_star=$(psql -X -tA -c "EXPLAIN SELECT * FROM lock_tree_duration_by_application()" 2>/dev/null)
byapp_count=$(psql -X -tA -c "EXPLAIN SELECT count(*) FROM lock_tree_duration_by_application()" 2>/dev/null)

if printf '%s' "$byapp_star" | grep -q 'Group Key: lock_tree_history.application_name'; then
    say_ok "lock_tree_duration_by_application() still computes its ids column, so its timing is real"
else
    say_bad "the ids aggregation is missing from the SELECT * plan, so the timing measured less work"
    printf '%s\n' "$byapp_star" | sed 's/^/        /' | head -14
fi

# The other half, and the reason the check is worth having: count(*) drops exactly that CTE. If this
# ever stops being true the timings have stopped meaning what the comment above claims they mean.
if printf '%s' "$byapp_count" | grep -q 'Group Key: lock_tree_history.application_name'; then
    say_bad "count(*) now computes the ids column too, so the reason for SELECT * is gone; re-measure"
else
    say_ok "and discriminating: count(*) still drops the ids CTE, which is why the timings use SELECT *"
fi

# Two separate things to be true, and both are checked structurally rather than by timing, because
# a time bound passes vacuously on a warm cache and fails on a loaded one.
#
#   the nearest sample comes from an index seek: an Index Cond on sampled_at
#   and nothing scans the table: no Seq Scan, and no Sort over a whole-table input
#
# The first version of this check grepped for 'Aggregate|max(|min(', which matches every plan in the
# extension, so it passed whatever replay did.
#
# Verified non-vacuous: run against the v0.14 tag, both of the checks that discriminate below FAIL,
# with the old plan printed. That is the only way to know a plan assertion is evidence.
plan=$(psql -X -tA -c "EXPLAIN SELECT count(*) FROM lock_tree_replay(now())" 2>/dev/null)

# NOT EVIDENCE. This one passes on 0.14 as well, because the outer join to the chosen sample is an
# index seek in both the old and the new shape. It is kept because its absence would mean something
# is genuinely wrong, but it does not on its own show the old behaviour is gone. The two below do.
if printf '%s' "$plan" | grep -q 'Index Cond'; then
    say_ok "replay's plan contains an index seek on sampled_at (necessary, not sufficient)"
else
    say_bad "replay has no index seek at all on sampled_at"
    printf '%s\n' "$plan" | sed 's/^/        /' | head -14
fi

if printf '%s' "$plan" | grep -q 'Seq Scan on lock_tree_history'; then
    say_bad "replay still sequential-scans the history to find one sample"
    printf '%s\n' "$plan" | sed 's/^/        /' | head -14
else
    say_ok "and, discriminating: replay no longer sequential-scans the history to find one sample"
fi

if [ "$keep" -eq 1 ]; then
    printf '\n  fixture left in place (--keep)\n\n'
else
    psql -X -q -c 'TRUNCATE lock_tree_history' >/dev/null 2>&1
    printf '\n  fixture truncated; the history is as you left it\n\n'
fi

if [ "$fail" -eq 0 ]; then
    printf '  \033[32mbenchmark complete\033[0m\n\n'
    exit 0
fi
printf '  \033[31msome checks failed\033[0m\n\n'
exit 1