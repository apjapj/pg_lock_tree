#!/usr/bin/env bash
# check-alert.sh: prove that lock_tree_notify() actually delivers a NOTIFY a listener can read, that
# lock_tree_notify_resolved() delivers the matching 'cleared' one, and explain what either means.
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

# ---------------------------------------------------------------- the notification stream
#
# ONE listener and ONE session that holds the chain for the whole sequence, rather than a listener
# per phase. The reason is not tidiness.
#
# A psql session that exits takes its dblink backends with it. This script used to build the chain in
# one psql invocation, notify in it, and then check for silence in a LATER invocation. By then the
# chain was gone, so lock_tree_notify()'s own sweep had already deleted the stored alert row, and the
# silence check passed for the wrong reason: it was reading a tree with nothing in it. That also
# left nothing for lock_tree_notify_resolved() to resolve, which is how a run of this script once
# reported zero cleared roots while the assertion beside it demanded one.
#
# So: the chain, both onset calls, both resolution calls and the teardown all happen inside one psql
# session. The listener sits in the background for the whole of it, and the payload stream is
# asserted as a sequence rather than per phase. That checks delivery, silence, ordering and teardown
# in one pass, through a real client, which a TAP assertion cannot do.
tmp=$(mktemp -d)

(
  psql -X -q -A -t > "$tmp/listener.out" 2>&1 <<'SQL'
\set ON_ERROR_STOP on
LISTEN lock_tree;
-- NOTIFY is only delivered at a command boundary, so a single long pg_sleep holds the notifications
-- until it returns and the file stays empty the whole time. This script had exactly that: one
-- pg_sleep(8), which only worked because the run finished inside the window by luck. One statement
-- per second is a command boundary per second, and \gexec runs them as separate statements.
SELECT 'SELECT pg_sleep(1)' FROM generate_series(1, 60) \gexec
SQL
) &
listener=$!
trap 'rm -rf "$tmp"; kill "$listener" 2>/dev/null' EXIT

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
SELECT 'FIRED=' || lock_tree_notify('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
-- Same arguments again. Must send nothing: this is the noise the design exists to avoid, and it is
-- only meaningful here because the chain from the line above is still standing.
SELECT 'REPEAT=' || lock_tree_notify('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
-- Same thresholds again, as lock_tree_notify_resolved() requires. The chain is still up, so nothing
-- may be resolved: standing on-call down while the queue is still there is the failure to avoid.
SELECT 'MID=' || lock_tree_notify_resolved('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
-- Now take the chain down. DISCONNECT rather than terminate: both end it, but terminating kills the
-- dblink backend and dblink_disconnect then fails with 'connection "ah" not available', which
-- aborted this script outright when it was written the other way round. Disconnecting releases the
-- lock as a side effect, so the waiter completes and the tree empties with nothing killed.
DO $x$ BEGIN
  BEGIN PERFORM dblink_disconnect('ah'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('aw'); EXCEPTION WHEN OTHERS THEN NULL; END;
END $x$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE application_name = 'alert_check');
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
SELECT 'CLEARED=' || lock_tree_notify_resolved('lock_tree', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
SELECT 'LEFT=' || count(*) FROM lock_tree_alert;
SQL
)

# Prefixed rather than positional. dblink_send_query also returns a bare 1, and counting integer
# lines picked that up as the notification count, which is how the first run of this reported a
# repeat call that had in fact sent nothing as one that notified again.
tag() { printf '%s\n' "$out" | sed -n "s/^$1=\([0-9]*\)$/\1/p" | head -1; }
fired=$(tag FIRED)
repeat=$(tag REPEAT)
mid=$(tag MID)
cleared=$(tag CLEARED)
left=$(tag LEFT)

if [ "${fired:-0}" -ge 1 ] 2>/dev/null; then
    say_ok "lock_tree_notify() reported $fired notification(s)"
else
    say_bad "lock_tree_notify() reported nothing fired; psql said: ${out:-nothing}"
fi

if [ "${repeat:-x}" = "0" ]; then
    say_ok 'a second identical call is silent, which is the noise this design exists to avoid'
else
    say_bad "a second identical call reported ${repeat:-?}, so it notified again"
fi

if [ "${mid:-x}" = "0" ]; then
    say_ok 'nothing is resolved while the incident is still standing'
else
    say_bad "lock_tree_notify_resolved() reported ${mid:-?} while the chain was still blocked"
fi

if [ "${cleared:-0}" -ge 1 ] 2>/dev/null; then
    say_ok "lock_tree_notify_resolved() reported $cleared cleared root(s) once the chain was gone"
else
    say_bad "lock_tree_notify_resolved() reported nothing after the chain ended; psql said: ${out:-nothing}"
fi

if [ "${left:-x}" = "0" ]; then
    say_ok 'and the stored state is forgotten, so the next incident alerts from the start'
else
    say_bad "lock_tree_alert still holds ${left:-?} row(s) after resolution"
fi

# Now the delivery side, from the one listener that was up for the whole of it.
sleep 0.6
got=$(cat "$tmp/listener.out" 2>/dev/null)
payloads=$(printf '%s' "$got" | sed -n 's/.*payload "\(.*\)" received.*/\1/p')
n_payloads=$(printf '%s\n' "$payloads" | grep -c .)

if [ "${n_payloads:-0}" -ge 2 ] 2>/dev/null; then
    say_ok "both notifications reached a separate LISTENing client, $n_payloads payload(s) in all"
else
    say_bad "the listener received ${n_payloads:-0} payload(s), expected 2; it said: ${got:-nothing}"
fi

# Exactly two, and in that order. The count is the silence check seen from the other end: a third
# payload would be the repeat call leaking, which "reported 0" on its own cannot rule out, since a
# function that returns 0 while still sending something is precisely the bug worth catching.
payload1=$(printf '%s\n' "$payloads" | sed -n 1p)
payload2=$(printf '%s\n' "$payloads" | sed -n 2p)
if [ "${n_payloads:-0}" = "2" ] 2>/dev/null; then
    say_ok 'and no more than those two, so the repeat call really did send nothing'
else
    say_bad "the listener saw ${n_payloads:-0} payloads, so at least one unwanted notification was sent"
fi

event_of() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("event","(none)"))' 2>/dev/null; }
has_key() { printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$2' in d else 1)" 2>/dev/null; }

if [ "$(event_of "${payload1:-}")" = "alerting" ]; then
    say_ok 'the first payload says event = "alerting"'
else
    say_bad "the first payload does not say alerting: ${payload1:-nothing}"
fi

if has_key "${payload1:-}" blocked_sessions && has_key "${payload1:-}" max_depth; then
    say_ok 'and blocked_sessions and max_depth, which is the documented contract'
else
    say_bad "the alerting payload is missing documented keys: ${payload1:-nothing}"
fi

if has_key "${payload1:-}" root_pid; then
    say_ok 'and root_pid, so a listener can route on it'
else
    say_bad "the alerting payload cannot be routed on: ${payload1:-nothing}"
fi

if [ "$(event_of "${payload2:-}")" = "cleared" ]; then
    say_ok 'the second says event = "cleared", so a consumer gets the pair on one channel'
else
    say_bad "the second payload does not say cleared: ${payload2:-nothing}"
fi

if has_key "${payload2:-}" root_pid && has_key "${payload2:-}" application_name; then
    say_ok 'and names the root and its application, so a cleared notice is identifiable after the fact'
else
    say_bad "the cleared payload cannot be attributed: ${payload2:-nothing}"
fi

if [ "$mode" = "--explain" ] && [ -n "$payload1" ]; then
    hdr 'And what you would do with it'
    explain_payload "$payload1"
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