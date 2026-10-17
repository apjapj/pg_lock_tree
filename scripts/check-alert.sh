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
# ---------------------------------------------------------------- the explanation
#
# Deliberately no database access. It has to work on a laptop with the VPN down, from a payload
# someone pasted out of a chat message, and it must not itself be a thing that can hang at 3am.
#
# Both event kinds are explained, and they are explained differently on purpose. An `alerting`
# payload is a question: what do I run. A `cleared` payload is a statement about the past, and the
# useful output is what the incident WAS, because that is what someone reviewing it at 4pm wants.
# Handing a cleared payload to the alerting branch would print "Run these, in this order" and
# pg_terminate_backend on a pid that has already gone.
explain_payload() {
    local payload=$1
    printf '\n'
    python3 - "$payload" <<'PY'
import json, sys


def sql_str(v):
    """A SQL string literal. json.dumps is not one: it emits double quotes, which PostgreSQL reads
    as an identifier, so every query it produced would have failed the moment it was pasted."""
    return "'" + str(v).replace("'", "''") + "'"


def explain_alerting(d):
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
    print("  event: %s" % (d.get('event') or '(none: sent before 0.12, which added the key)'))
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
    print("  See docs/alerting.md for how the thresholds are meant to be set.")


def explain_cleared(d):
    pid      = d.get('root_pid')
    obj      = d.get('root_object')
    app      = d.get('application_name') or '(none set)'
    at_most  = d.get('blocked_at_most')
    notified = d.get('notified_count')
    channel  = d.get('channel') or 'lock_tree'
    prepared = (pid == 0)

    print("  What this says")
    print("  -------------")
    print("  event: cleared, on channel %s." % channel)
    print("  An incident that had already alerted has ended: the root is out of the queue.")
    if prepared:
        print("  The root was a PREPARED TRANSACTION, so it was released by ROLLBACK PREPARED")
        print("  rather than by a session ending, and no pid was ever involved.")
    else:
        print("  The root was pid %s, which has since left the tree." % pid)
    print("  It was %s." % app)
    if obj:
        print("  It had been holding %s." % obj)
    print("  At its worst it was blocking %s session(s)." % at_most)
    if notified is not None:
        print("  It alerted %s time(s), which counts escalations as well as the onset." % notified)

    print()
    print("  What it means")
    print("  -------------")
    print("  Nothing is blocked by this root any more. If the queue is empty you can stand down.")
    print("  Check before you do, though: one root clearing says nothing about the next one.")
    print()
    print("  If it escalated more than once before clearing, that is the part worth reading. A")
    print("  chain that alerted once and cleared is routine. A chain that escalated while getting")
    print("  worse is the one that tells you what to change, and once the history is pruned this")
    print("  payload is the only record of it.")

    print()
    print("  Look this up")
    print("  -------------")
    print("  -- 1. is anything blocked right now? Decide before you close the page.")
    print("  SELECT sessions_blocked, roots, longest_wait FROM lock_tree_summary();")
    print()
    print("  -- 2. what the application cost you in the sampled history")
    print("  SELECT application_name, blocking_seconds, blocked_sessions_peak, longest_wait")
    print("    FROM lock_tree_duration_by_application()")
    print("   WHERE application_name = %s;" % sql_str(app))
    print()
    print("  -- 3. every incident that application was in, not just this one")
    print("  SELECT started_at, ended_at, peak_sessions, peak_depth, longest_wait")
    print("    FROM lock_tree_incidents()")
    print("   WHERE %s = ANY(applications) ORDER BY started_at DESC LIMIT 10;" % sql_str(app))
    print()
    print("  -- 4. the pid is gone, so this finds anything only while the history still holds it.")
    print("  --    Depth 0 is the root; the rows beneath it are what it was holding up.")
    print("  SELECT sampled_at, depth, state, waiting_for, wait_age, left(query, 120) AS query")
    print("    FROM lock_tree_history WHERE root_pid = %s" % pid)
    print("   ORDER BY sampled_at, depth;")
    print()
    print("  -- 5. and whether this application blocking is a pattern rather than a one-off")
    print("  SELECT application, count(*) AS incidents, sum(peak_sessions) AS sessions_hit")
    print("    FROM lock_tree_incidents(), unnest(applications) AS u(application)")
    print("   GROUP BY application ORDER BY sessions_hit DESC LIMIT 10;")


def main():
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
        return

    # Dispatch on the event key. Anything that is not explicitly 'cleared' is explained as an
    # onset, INCLUDING a payload with no event key at all, which is what every pre-0.12
    # notification looks like. Those had exactly one meaning, so treating them as onsets is right,
    # and it is the only place in this script where an absent key is read as a present one.
    if d.get('event') == 'cleared':
        explain_cleared(d)
    else:
        explain_alerting(d)


main()
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

# 3, not 1: a script that cannot reach a server or find the extension has not run, and a caller
# recording this as a defect check must be able to tell that from a real failure. The defect
# harness records a cell with this script as its command, and reads 3 as could-not-run. Either the
# extension is installed, or the release script was loaded straight into the schema, which is how
# the harness and the pgTAP matrix use it, so a loaded script counts as present.
if ! psql -X -tAc "SELECT 1 WHERE to_regclass('lock_tree') IS NOT NULL
                      OR EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree')" 2>/dev/null | grep -q 1; then
    echo "  pg_lock_tree is not available in this database, or the server cannot be reached" >&2
    exit 3
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

# ---------------------------------------------------------------- two roots, one escalating
#
# The first stream has one root, and a defect that needs two roots cannot show in it. root_fired in
# lock_tree_notify() is meant to be per root; until 1.1.15 it was reset only for roots below every
# threshold, so once one root fired, every later root that was notable but UNCHANGED was notified
# again with the payload it had already had, while the function's return value said it had not. Only
# the listener can see that, which is why it is asserted here and not in test/11.
#
# The waiters carry an application_name that sorts after the roots' names, deliberately: until 1.1.15
# lock_tree_wide() took max(application_name) over the whole tree, waiters included, so a waiter
# whose name sorted last was reported as the root's application, in the payload a pager keys on.
hdr 'Two roots: one escalates, the other must stay quiet'
(
  psql -X -q -A -t > "$tmp/listener2.out" 2>&1 <<'SQL'
\set ON_ERROR_STOP on
LISTEN lock_tree_two;
SELECT 'SELECT pg_sleep(1)' FROM generate_series(1, 25) \gexec
SQL
) &
listener2=$!
sleep 0.6

out2=$(psql -X -q -A -t 2>&1 <<'SQL'
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
DROP TABLE IF EXISTS alert_two_a, alert_two_b;
CREATE TABLE alert_two_a (id int);
CREATE TABLE alert_two_b (id int);
DELETE FROM lock_tree_alert WHERE channel = 'lock_tree_two';
SELECT dblink_connect('r1', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_connect('r2', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('r1', 'SET application_name = ''alert_check_one''');
SELECT dblink_exec('r2', 'SET application_name = ''alert_check_two''');
SELECT dblink_exec('r1', 'BEGIN');
SELECT dblink_exec('r1', 'LOCK TABLE alert_two_a IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('r2', 'BEGIN');
SELECT dblink_exec('r2', 'LOCK TABLE alert_two_b IN ACCESS EXCLUSIVE MODE');
-- r1: one waiter now and five more later. r2: three waiters throughout.
SELECT dblink_connect('w' || i, format('dbname=%s user=%s', current_database(), current_user))
  FROM generate_series(1, 9) i;
SELECT dblink_exec('w' || i, 'SET application_name = ''zz_waiter''') FROM generate_series(1, 9) i;
SELECT dblink_send_query('w1', 'SELECT count(*) FROM alert_two_a');
SELECT dblink_send_query('w' || i, 'SELECT count(*) FROM alert_two_b') FROM generate_series(2, 4) i;
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks WHERE NOT granted
                AND relation IN ('alert_two_a'::regclass, 'alert_two_b'::regclass)) = 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
SELECT 'ONSET=' || lock_tree_notify('lock_tree_two', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
SELECT dblink_send_query('w' || i, 'SELECT count(*) FROM alert_two_a') FROM generate_series(5, 9) i;
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks WHERE NOT granted
                AND relation = 'alert_two_a'::regclass) = 6;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
SELECT 'ESCALATE=' || lock_tree_notify('lock_tree_two', min_blocked => 1, min_depth => NULL, min_wait => NULL);
SELECT pg_sleep(0.5);
SELECT 'ROOTAPPS=' || string_agg(application_name, ',' ORDER BY application_name)
  FROM lock_tree_wide() WHERE root_pid IN (SELECT pid FROM pg_stat_activity
                                            WHERE application_name LIKE 'alert_check_%');
DO $x$ BEGIN
  FOR i IN 1..9 LOOP
    BEGIN PERFORM dblink_disconnect('w' || i); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  BEGIN PERFORM dblink_disconnect('r1'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('r2'); EXCEPTION WHEN OTHERS THEN NULL; END;
END $x$;
DELETE FROM lock_tree_alert WHERE channel = 'lock_tree_two';
DROP TABLE IF EXISTS alert_two_a, alert_two_b;
SQL
)
wait "$listener2" 2>/dev/null
tag2() { printf '%s\n' "$out2" | sed -n "s/^$1=\(.*\)$/\1/p" | head -1; }
onset=$(tag2 ONSET); escalate=$(tag2 ESCALATE); rootapps=$(tag2 ROOTAPPS)
got2=$(cat "$tmp/listener2.out" 2>/dev/null)
payloads2=$(printf '%s' "$got2" | sed -n 's/.*payload "\(.*\)" received.*/\1/p')
n2=$(printf '%s\n' "$payloads2" | grep -c .)
apps2=$(printf '%s\n' "$payloads2" | python3 -c '
import json, sys
print(",".join(sorted({json.loads(l)["application_name"] for l in sys.stdin if l.strip()})))' 2>/dev/null)

if [ "$onset" = "2" ] && [ "$escalate" = "1" ]; then
    say_ok 'lock_tree_notify() reported 2 at onset and 1 when only one root escalated'
else
    say_bad "lock_tree_notify() reported ${onset:-?} at onset and ${escalate:-?} at escalation, expected 2 and 1; psql said: ${out2:-nothing}"
fi
if [ "${n2:-0}" = "3" ] 2>/dev/null; then
    say_ok 'and the listener received exactly 3: two onsets and one escalation, nothing for the quiet root'
else
    say_bad "the listener received ${n2:-0} payload(s), expected 3, so the unchanged root was notified again"
fi
if [ "$rootapps" = "alert_check_one,alert_check_two" ]; then
    say_ok "lock_tree_wide() names each root by the root's own application, not a waiter's"
else
    say_bad "lock_tree_wide() named the roots '${rootapps:-?}', expected alert_check_one,alert_check_two"
fi
if [ "$apps2" = "alert_check_one,alert_check_two" ]; then
    say_ok 'and so does every payload, which is the key a listener is told to route on'
else
    say_bad "the payloads named '${apps2:-?}' as the application, expected alert_check_one,alert_check_two"
fi

# ---------------------------------------------------------------- a root that comes back mid-resolve
#
# Until 1.1.16 lock_tree_notify_resolved() read the live tree twice: a SELECT chose which roots to
# report cleared, and a separate DELETE chose which state to forget. A root that started blocking
# again between the two was reported cleared and KEPT, so the next lock_tree_notify() saw its row,
# treated it as already alerted, and sent nothing for an incident that was still going on.
#
# The gap is opened deterministically. The resolver runs with a search_path that puts a pg_notify
# which sleeps for three seconds ahead of pg_catalog's, and while it sleeps, a session connected
# before the call starts waiting on the same root. The session has to be connected first: a backend
# that starts later is not in the resolver's pg_stat_activity snapshot and cannot be seen at all.
# Fixed, the decision and the deletion are one statement, so whatever is reported cleared is gone,
# and the root's return is a fresh incident that alerts again.
hdr 'A root that comes back while it is being resolved'
out3=$(psql -X -q -A -t 2>&1 <<'SQL'
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
DROP TABLE IF EXISTS alert_race;
CREATE TABLE alert_race (id int);
DELETE FROM lock_tree_alert WHERE channel = 'lock_tree_race';
DROP SCHEMA IF EXISTS alert_race_slow CASCADE;
CREATE SCHEMA alert_race_slow;
CREATE FUNCTION alert_race_slow.pg_notify(text, text) RETURNS void LANGUAGE plpgsql
  AS $f$ BEGIN PERFORM pg_sleep(3); PERFORM pg_catalog.pg_notify($1, $2); END $f$;
SELECT dblink_connect(c, format('dbname=%s user=%s', current_database(), current_user))
  FROM unnest(ARRAY['race_root', 'race_w1', 'race_w2', 'race_res']) AS c;
SELECT dblink_exec('race_root', 'BEGIN');
SELECT dblink_exec('race_root', 'LOCK TABLE alert_race IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('race_w1', 'SELECT count(*) FROM alert_race');
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks WHERE NOT granted AND relation = 'alert_race'::regclass) = 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
SELECT 'ONSET=' || lock_tree_notify('lock_tree_race', min_blocked => 1, min_depth => NULL, min_wait => NULL);
-- The waiter gives up, so the root is no longer a root.
SELECT dblink_cancel_query('race_w1');
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks WHERE NOT granted AND relation = 'alert_race'::regclass) = 0;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
SELECT dblink_exec('race_res', 'SET search_path = alert_race_slow, ' || current_schema() || ', pg_catalog');
SELECT dblink_send_query('race_res',
  'SELECT lock_tree_notify_resolved(''lock_tree_race'', min_blocked => 1, min_depth => NULL, min_wait => NULL)');
SELECT pg_sleep(1);
-- While the resolver sleeps inside its loop, the same root starts blocking again.
SELECT dblink_send_query('race_w2', 'SELECT count(*) FROM alert_race');
SELECT 'CLEARED=' || n FROM dblink_get_result('race_res') AS t(n bigint);
SELECT 'BLOCKING=' || count(*) FROM pg_locks WHERE NOT granted AND relation = 'alert_race'::regclass;
SELECT 'KEPT=' || count(*) FROM lock_tree_alert WHERE channel = 'lock_tree_race';
SELECT 'NEXT=' || lock_tree_notify('lock_tree_race', min_blocked => 1, min_depth => NULL, min_wait => NULL);
DO $x$ BEGIN
  BEGIN PERFORM dblink_disconnect('race_w1'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('race_w2'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('race_res'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM dblink_disconnect('race_root'); EXCEPTION WHEN OTHERS THEN NULL; END;
END $x$;
DELETE FROM lock_tree_alert WHERE channel = 'lock_tree_race';
DROP SCHEMA alert_race_slow CASCADE;
DROP TABLE IF EXISTS alert_race;
SQL
)
tag3() { printf '%s\n' "$out3" | sed -n "s/^$1=\(.*\)$/\1/p" | head -1; }
r_onset=$(tag3 ONSET); r_cleared=$(tag3 CLEARED); r_blocking=$(tag3 BLOCKING); r_kept=$(tag3 KEPT); r_next=$(tag3 NEXT)
if [ "$r_onset" = "1" ] && [ "$r_blocking" = "1" ]; then
    say_ok 'the root alerted, cleared, and was blocking again by the time the resolver finished'
else
    say_bad "the fixture did not form: onset ${r_onset:-?}, blocking at the end ${r_blocking:-?}; psql said: ${out3:-nothing}"
fi
if [ "$r_cleared" = "1" ] && [ "$r_kept" = "0" ]; then
    say_ok 'what was reported cleared was also forgotten: one decision, not two reads of the tree'
else
    say_bad "the resolver reported ${r_cleared:-?} cleared but kept ${r_kept:-?} alert row(s)"
fi
if [ "$r_next" = "1" ]; then
    say_ok 'so the root coming back is a new incident, and alerts again'
else
    say_bad "the next lock_tree_notify() sent ${r_next:-?}: an incident still under way is now silent"
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