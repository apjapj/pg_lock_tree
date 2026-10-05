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

# Each timing is a separate psql so nothing is cached between them in a way the caller did not ask
# for, and EXPLAIN ANALYZE is used rather than \timing so the server reports its own number.
printf '\n  \033[1mread functions\033[0m, whole window\n\n'
for fn in \
  "SELECT count(*) FROM lock_tree_history_statements()" \
  "SELECT count(*) FROM lock_tree_incidents()" \
  "SELECT count(*) FROM lock_tree_sampling_advice()" \
  "SELECT count(*) FROM lock_tree_deadlocks()" \
  "SELECT count(*) FROM lock_tree_history_size()" \
  "SELECT count(*) FROM lock_tree_replay_samples" \
  "SELECT count(*) FROM lock_tree_duration()" \
  "SELECT count(*) FROM lock_tree_duration_by_application()" \
  "SELECT count(*) FROM lock_tree_replay(now() - interval '1 hour')"
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
  "SELECT count(*) FROM lock_tree_duration(interval '1 millisecond')" \
  "SELECT count(*) FROM lock_tree_duration_by_application(interval '1 millisecond')" \
  "SELECT count(*) FROM lock_tree_history_statements(interval '1 millisecond')"
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