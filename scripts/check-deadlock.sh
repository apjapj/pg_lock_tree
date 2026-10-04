#!/usr/bin/env bash
# check-deadlock.sh: prove that a REAL deadlock moves pg_stat_database.deadlocks, and that the
# sample records it.
#
# Why this is a script and not a test file. The counter only moves when the server decides to break
# the cycle, which is `deadlock_timeout` after the wait began. Three separate attempts inside a
# single psql session all failed, each in a different and instructive way:
#
#   1. The deadlock was built from dblink connections belonging to the session that was also
#      sampling. The two interfered and the deadlock was never observed at all.
#   2. Waiting on the counter is circular. The counter only moves once the server has broken the
#      cycle, and it breaks that on a timer, so a loop that gives up early never sees the move and
#      reports that nothing happened.
#   3. Waiting for the CYCLE first and then for the counter works, but only if the sample is a
#      separate process. In one session the sampling connection was still holding something.
#
# scenarios/s6_deadlock.sql builds a real deadlock, but it raises deadlock_timeout to 15s so the
# cycle is still visible for its assertions, which means the increment lands long after that
# scenario has moved on. So the two live in different places: the scenario shows the cycle, this
# shows the counter.
#
# Needs superuser, dblink, and max_prepared_transactions is NOT required.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER

fail=0
say_ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
say_bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

if ! psql -X -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree'" 2>/dev/null | grep -q 1; then
    echo "  pg_lock_tree is not installed in this database" >&2
    exit 1
fi
psql -X -q -c 'CREATE EXTENSION IF NOT EXISTS dblink' >/dev/null 2>&1

# Nothing left over from a previous run, or the tables below cannot be dropped and the sessions
# below cannot be reconnected.
psql -X -q >/dev/null 2>&1 <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE pid <> pg_backend_pid() AND application_name LIKE 'chk_dl_%';
DO $b$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM unnest(ARRAY['chk_dl_f','chk_dl_g']) AS n LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
SQL

db=${PGDATABASE:-$(psql -X -tAc 'SELECT current_database()')}

printf '\n  \033[1mstep 1: baseline\033[0m\n'
psql -X -q >/dev/null 2>&1 <<'SQL'
TRUNCATE lock_tree_deadlock;
SELECT lock_tree_sample();
SQL
before=$(psql -X -tAc "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
say_ok "counter before the deadlock: $before"

printf '\n  \033[2mstep 2: deadlock, in a separate process\033[0m\n'
# The separate process is the whole point. It exits as soon as the cycle has formed, which leaves
# the two dblink backends connected and deadlocked, and the server to break them on its own timer.
psql -X -q >/dev/null 2>&1 <<SQL
SET client_min_messages = warning;
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['chk_dl_f','chk_dl_g']) AS n;
DROP TABLE IF EXISTS chk_dl_x; DROP TABLE IF EXISTS chk_dl_y;
CREATE TABLE chk_dl_x (id int); CREATE TABLE chk_dl_y (id int);
-- LEFT at the default deadlock_timeout, unlike s6. The whole point here is to let the server break
-- the cycle, because that is when the counter moves.
SELECT dblink_exec('chk_dl_f','SET application_name = ''chk_dl_f''');
SELECT dblink_exec('chk_dl_g','SET application_name = ''chk_dl_g''');
SELECT dblink_exec('chk_dl_f','BEGIN');
SELECT dblink_exec('chk_dl_g','BEGIN');
SELECT dblink_exec('chk_dl_f','LOCK TABLE chk_dl_x IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('chk_dl_g','LOCK TABLE chk_dl_y IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('chk_dl_f','LOCK TABLE chk_dl_y IN ACCESS EXCLUSIVE MODE');
SELECT pg_sleep(0.3);
SELECT dblink_send_query('chk_dl_g','LOCK TABLE chk_dl_x IN ACCESS EXCLUSIVE MODE');
DO \$w\$ BEGIN
  FOR i IN 1..150 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
                WHERE wait_event_type = 'Lock' AND query LIKE 'LOCK TABLE chk_dl_%') >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END \$w\$;
SQL

blocked=$(psql -X -tAc "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'LOCK TABLE chk_dl_%'")
if [ "${blocked:-0}" -ge 2 ] 2>/dev/null; then
    say_ok "both sessions are blocked on each other: that is a real cycle"
else
    say_bad "the cycle did not form (${blocked:-0} waiting); nothing below means anything"
fi

printf '\n  \033[2mstep 3: wait for the server to break it, then sample\033[0m\n'
moved=0
for _ in $(seq 1 60); do
    now=$(psql -X -tAc "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
    if [ "${now:-0}" -gt "${before:-0}" ] 2>/dev/null; then moved=1; break; fi
    sleep 1
done

if [ "$moved" -eq 1 ]; then
    say_ok "the counter moved, from $before to $now"
else
    say_bad "the counter never moved within 60s; it is still $now"
fi

# Now nothing is blocked, which is the case that leaves no trace in lock_tree_history.
still=$(psql -X -tAc "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock'")
if [ "${still:-1}" -eq 0 ] 2>/dev/null; then
    say_ok 'and nothing is blocked now, so lock_tree_history would record nothing at all'
else
    say_bad "${still:-?} sessions are still blocked, so this is not the case being claimed"
fi

rows=$(psql -X -tAc 'SELECT lock_tree_sample()')
if [ "${rows:-x}" = "0" ] 2>/dev/null; then
    say_ok 'a sample wrote no history rows, because the tree is empty'
else
    say_bad "the sample wrote ${rows:-?} history rows, so the tree was not empty"
fi

report=$(psql -X -tA -c 'SELECT delta FROM lock_tree_deadlocks() ORDER BY sampled_at DESC LIMIT 1' 2>/dev/null | head -1)
if [ -n "$report" ] && [ "${report:-0}" -ge 1 ] 2>/dev/null; then
    say_ok "and lock_tree_deadlocks() reports the move: delta = $report"
else
    say_bad "lock_tree_deadlocks() reported no movement; last delta was '${report:-nothing}'"
fi

stored=$(psql -X -tAc 'SELECT deadlocks FROM lock_tree_deadlock ORDER BY sampled_at DESC LIMIT 1')
live=$(psql -X -tAc "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
if [ "${stored:-x}" = "${live:-y}" ]; then
    say_ok "the stored sample agrees with the live counter, both $live"
else
    say_bad "stored $stored but live is $live, so the sample read a different counter"
fi

printf '\n  \033[2mwhat it does not do\033[0m\n'
printf '  This names no statements. pg_stat_database.deadlocks is a bare counter with no\n'
printf '  attribution, and the two statements involved exist only in the server log. The\n'
printf '  timestamp this reports is how you find the right log entry. See the Deadlocks\n'
printf '  section of README.md for the log_lock_waits recipe.\n'

# Clean up. Terminate rather than cancel: a cancelled session stays connected holding an aborted
# transaction and would still appear in the next run's tree.
psql -X -q >/dev/null 2>&1 <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE pid <> pg_backend_pid() AND application_name LIKE 'chk_dl_%';
DO $b$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM unnest(ARRAY['chk_dl_f','chk_dl_g']) AS n LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE IF EXISTS chk_dl_x;
DROP TABLE IF EXISTS chk_dl_y;
TRUNCATE lock_tree_deadlock;
SQL

if [ "$fail" -eq 0 ]; then
    printf '\n  \033[32mall checks passed\033[0m\n\n'
    exit 0
else
    printf '\n  \033[31msome checks failed\033[0m\n\n'
    exit 1
fi