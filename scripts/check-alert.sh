#!/usr/bin/env bash
# check-alert.sh: prove that lock_tree_notify() actually delivers a NOTIFY a listener can read, and
# explain what one means.
#
# Why this is a script and not a pgTAP assertion: psql prints notifications to stdout rather than
# storing them, and a TAP assertion cannot see stdout. So the delivery path is verified here, by
# listening and reading this script's own output. test/11_alert.sql covers the decisions, which is
# the part worth unit-testing; this covers the part only a real client can confirm.
#
#   ./scripts/check-alert.sh                 build a chain, notify, read the payload back
#   ./scripts/check-alert.sh --explain       the same, then explain the payload
#   ./scripts/check-alert.sh --explain '…'   explain a payload you already have, from a pager
#
# The third form is the one that matters at 3am. It needs no database: paste the payload and it
# prints what it means and the queries to run, so the first thing you do is not to think.
#
# Needs superuser and dblink.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER

mode=${1:-check}
supplied=${2:-}

fail=0
say_ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
say_bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
hdr()     { printf '\n  \033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- the explanation
#
# Deliberately no database access. It has to work on a laptop with the VPN down, from a payload
# someone pasted out of a chat message, and it must not itself be a thing that can hang at 3am.
explain_payload() {
    local payload=$1
    printf '\n'
    python3 - "$payload" <<'PY'
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("  This is not JSON, so it did not come from lock_tree_notify(). The nearest")
    print("  explanation is that something else on the channel sent it.")
    print("  Parse error: %s" % e)
    sys.exit(1)

if not isinstance(d, dict) or 'root_pid' not in d:
    print("  No root_pid, so this is not a pg_lock_tree alert either. A listener that")
    print("  receives several kinds of message on one channel should route on that key.")
    sys.exit(0)

pid      = d.get('root_pid')
obj      = d.get('root_object')
app      = d.get('application_name') or '(none set)'
blocked  = d.get('blocked_sessions')
depth    = d.get('max_depth')
waited   = d.get('longest_wait')
waiting  = d.get('waiting_for')
prepared = (pid == 0)

print("  What this says")
print("  -------------")
print("  A root blocker is holding up %s session(s), in a chain %s deep." % (blocked, depth))
print("  The longest anyone in it has been waiting is %s." % waited)
print("  The waiters want %s." % waiting)
print("  The blocker is %s." % app)
if obj:
    print("  It is holding %s." % obj)

print()
print("  What it means")
print("  -------------")
if prepared:
    print("  The blocker is a PREPARED TRANSACTION. It has no backend, no session and no")
    print("  application_name, which is why the root pid is 0 and the name is empty.")
    print("  Nothing you can do to a session will clear this. pg_cancel_backend(0) returns")
    print("  false and warns that pid 0 is not a backend; pg_terminate_backend(0) likewise.")
    print("  The only remedy is ROLLBACK PREPARED, and you need the gid.")
else:
    print("  The blocker is an ordinary session, so it can be cancelled and then terminated.")
    print("  A session that has been 'idle in transaction' is almost always the problem: it is")
    print("  holding locks from work it has already finished, and nothing will release them")
    print("  until it ends. Check its query and its xact_start before killing it, because if")
    print("  it is mid-migration or mid-reindex you may prefer to wait.")

print()
print("  Run these, in this order")
print("  ------------------------")
if prepared:
    print("  SELECT gid, prepared, owner FROM pg_prepared_xacts;")
    print("    -- pick the gid whose prepared time is close to the incident, then:")
    print("  ROLLBACK PREPARED '<gid>';")
    print("  -- the lock it holds is: %s" % (obj or "(not recorded)"))
else:
    print("  -- 1. see the whole chain before acting on it")
    print("  SELECT * FROM lock_tree WHERE root_pid = %s ORDER BY path;" % pid)
    print()
    print("  -- 2. what the blocker is actually doing")
    print("  SELECT pid, state, xact_start, left(query, 200) FROM pg_stat_activity")
    print("   WHERE pid = %s;" % pid)
    print()
    print("  -- 3. one row per root, if the queue is wide and you only want the worst")
    print("  SELECT root_pid, root_object, blocked_sessions, longest_wait")
    print("    FROM lock_tree_wide() ORDER BY blocked_sessions DESC LIMIT 10;")
    print()
    print("  -- 4. if it still has not cleared, terminate it")
    print("  SELECT pg_terminate_backend(%s);" % pid)

print()
print("  Before you page anyone")
print("  ---------------------")
print("  An alert means a chain crossed a threshold, not that the database is down. Compare")
print("  against lock_tree_summary(): if blocked_sessions is a handful, this is a chain worth")
print("  naming, not an outage. If it is hundreds, it is an outage.")
print("  See the Alerting section of README.md for how the thresholds are meant to be set.")
PY
}

# ---------------------------------------------------------------- explain-only mode
if [ "$mode" = "--explain" ]; then
    if [ -n "$supplied" ]; then
        printf '  \033[1mExplaining a payload you supplied\033[0m\n'
        explain_payload "$supplied"
        exit $?
    fi
    # No payload supplied: build an incident below and explain what arrives.
fi

if ! psql -X -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree'" 2>/dev/null | grep -q 1; then
    echo "  pg_lock_tree is not installed in this database" >&2
    exit 1
fi

# A LISTENing client in its own background session, writing to a file.
#
# It has to be a separate session from the notifier, and the notifier's own session has to build
# the chain as well as raise the notification. A psql session that exits takes its dblink
# backends with it, so a chain built in an earlier invocation is simply gone by the time the
# notification is raised. This script hit exactly that before being restructured, and reported a
# false pass on the silence check while failing the delivery check.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(
  psql -X -q -A -t > "$tmp/listener.out" 2>&1 <<'SQL'
\set ON_ERROR_STOP on
LISTEN lock_tree;
SELECT pg_sleep(8);
SQL
) &
listener=$!
sleep 0.6   # let the listener reach LISTEN before anything can notify

out=$(psql -X -q -A -t 2>&1 <<'SQL'
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
DROP TABLE IF EXISTS alert_demo;
CREATE TABLE alert_demo (id int);
TRUNCATE lock_tree_alert;
SELECT dblink_connect('ah', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_connect('aw', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('ah', 'BEGIN');
SELECT dblink_exec('ah', 'SET application_name = ''alert_check''');
SELECT dblink_exec('ah', 'LOCK TABLE alert_demo IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('aw', 'SELECT count(*) FROM alert_demo');
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
                WHERE wait_event_type = 'Lock' AND query LIKE '%alert_demo%') = 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
-- min_depth and min_wait are off, so one blocked session is enough on its own.
SELECT lock_tree_notify('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL)
         AS fired;
SELECT pg_sleep(0.5);
SQL
)

fired=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*[0-9]+$' | head -1)
if [ "${fired:-0}" -ge 1 ] 2>/dev/null; then
    say_ok "lock_tree_notify() reported $fired notification(s)"
else
    say_bad "lock_tree_notify() reported nothing fired; psql said: ${out:-nothing}"
fi

wait "$listener" 2>/dev/null
got=$(cat "$tmp/listener.out" 2>/dev/null)

if printf '%s' "$got" | grep -q 'Asynchronous notification "lock_tree"'; then
    say_ok 'the notification reached a separate LISTENing client'
else
    say_bad "the listener received nothing; it said: ${got:-nothing}"
fi

payload=$(printf '%s' "$got" | sed -n 's/.*payload "\(.*\)" received.*/\1/p' | head -1)

if [ -n "$payload" ]; then
    say_ok 'and the notification carries a payload'
    if printf '%s' "$payload" | python3 -c 'import json,sys; sys.exit(0 if "root_pid" in json.load(sys.stdin) else 1)' 2>/dev/null; then
        say_ok 'which parses as JSON and carries root_pid, so a listener can route on it'
    else
        say_bad "the payload is not parseable JSON with root_pid: $payload"
    fi
    if printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "blocked_sessions" in d and "max_depth" in d else 1)' 2>/dev/null; then
        say_ok 'and blocked_sessions and max_depth, which is the documented contract'
    else
        say_bad "the payload is missing documented keys: $payload"
    fi
else
    say_bad 'no payload was delivered'
fi

# The repeat call must be silent. Checked in test/11_alert.sql as well; here it is checked through
# a real notification stream, which is the only way to be sure "0 returned" means "nothing sent".
(
  psql -X -q -A -t > "$tmp/listener2.out" 2>&1 <<'SQL'
\set ON_ERROR_STOP on
LISTEN lock_tree;
SELECT pg_sleep(4);
SQL
) &
listener2=$!
sleep 0.6

psql -X -q -A -t >/dev/null 2>&1 <<'SQL'
\set ON_ERROR_STOP on
SELECT lock_tree_notify('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SQL

wait "$listener2" 2>/dev/null
if grep -q 'Asynchronous notification' "$tmp/listener2.out" 2>/dev/null; then
    say_bad 'a second identical call notified again, which is the noise this design exists to avoid'
else
    say_ok 'a second identical call is silent, which is the noise this design exists to avoid'
fi

if [ "$mode" = "--explain" ] && [ -n "$payload" ]; then
    hdr 'And what you would do with it'
    explain_payload "$payload"
fi

# Clean up. Terminate rather than cancel: a cancelled session stays connected holding an aborted
# transaction and would still appear in the next run's tree.
psql -X -q >/dev/null 2>&1 <<'SQL'
\set ON_ERROR_STOP on
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE query LIKE '%alert_demo%' AND pid <> pg_backend_pid();
SELECT dblink_disconnect('ah');
SELECT dblink_disconnect('aw');
DROP TABLE IF EXISTS alert_demo;
TRUNCATE lock_tree_alert;
SQL

if [ "$fail" -eq 0 ]; then
    printf '\n  \033[32mall checks passed\033[0m\n\n'
    exit 0
else
    printf '\n  \033[31msome checks failed\033[0m\n\n'
    exit 1
fi