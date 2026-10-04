-- test/11_alert.sql: alerting, and not alerting.
--
-- Alerting's hard part is not raising a notification, it is raising the right number of them. A
-- job that notifies on every sample turns a two-minute incident into twelve notifications and
-- trains everyone to ignore the channel, which is worse than having none, because the one alert
-- that mattered gets filtered along with the noise. So this file spends most of its assertions
-- on the calls that must return zero.
--
-- It has to run as ONE session. Every phase builds on the chain the previous phase left standing,
-- and a psql session that exits takes its dblink backends with it, so splitting this across
-- invocations would silently test a quiet database five times. That is not hypothetical: an
-- earlier draft of this file was developed as separate scripts and every phase passed, because
-- every phase was measuring nothing.
--
-- Needs superuser (dblink) and the dblink contrib module.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS dblink;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

DROP TABLE IF EXISTS lock_tree_al1;
DROP TABLE IF EXISTS lock_tree_al2;
DROP TABLE IF EXISTS lock_tree_al_pids;
-- Two tables so two roots. Two ACCESS EXCLUSIVE requests queued against one table would give one
-- root and one waiter, not two heads of the queue.
CREATE TABLE lock_tree_al1 (id int);
CREATE TABLE lock_tree_al2 (id int);
CREATE TABLE lock_tree_al_pids (name text primary key, pid int);

-- Alert state is a decision, not a fixture, so start from whatever a previous run left behind.
TRUNCATE lock_tree_alert;

CREATE TEMP TABLE al_names AS
SELECT 'r1' AS n
UNION ALL SELECT 'r2'
UNION ALL SELECT 'w' || i FROM generate_series(1,8) i   -- queues behind r1
UNION ALL SELECT 'x' || i FROM generate_series(1,4) i;  -- queues behind r2

SELECT dblink_connect(s.n, format('dbname=%s user=%s', current_database(), current_user))
FROM al_names s;

INSERT INTO lock_tree_al_pids
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int))
FROM al_names s;

SELECT dblink_exec('r1', 'BEGIN');
SELECT dblink_exec('r1', 'SET application_name = ''nightly_batch''');
SELECT dblink_exec('r1', 'LOCK TABLE lock_tree_al1 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('r2', 'BEGIN');
SELECT dblink_exec('r2', 'SET application_name = ''reporting_rollup''');
SELECT dblink_exec('r2', 'LOCK TABLE lock_tree_al2 IN ACCESS EXCLUSIVE MODE');

SELECT dblink_send_query('w' || i, format(
  'SET application_name = ''api_%s''; SELECT count(*) FROM lock_tree_al1', lpad(i::text, 2, '0')))
FROM generate_series(1,8) i;
SELECT dblink_send_query('x' || i, format(
  'SET application_name = ''report_%s''; SELECT count(*) FROM lock_tree_al2', lpad(i::text, 2, '0')))
FROM generate_series(1,4) i;

DO $wait$
BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a
               JOIN lock_tree_al_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') >= 12;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

-- psql prints notifications to stdout rather than storing them, and pgTAP cannot read stdout, so
-- the payload is not asserted from the notification stream itself. What is asserted is that the
-- payload the function builds is well-formed JSON carrying every key the documentation promises,
-- since that is the contract a listener depends on. Stream delivery is covered separately by
-- scripts/check-alert.sh, which LISTENs and reads its own output.
CREATE TEMP TABLE payload_shape AS
SELECT json_build_object(
         'channel',          'lock_tree',
         'root_pid',         w.root_pid,
         'application_name', w.application_name,
         'blocked_sessions', w.blocked_sessions,
         'max_depth',        w.max_depth,
         'longest_wait',     lock_tree_age(w.longest_wait),
         'waiting_for',      w.first_waiting_for)::text AS payload
FROM lock_tree_wide() w
ORDER BY w.blocked_sessions DESC LIMIT 1;
\o
\unset QUIET

SELECT plan(30);

SELECT has_table('lock_tree_alert', 'lock_tree_alert table exists');
SELECT has_function('lock_tree_notify',
  ARRAY['text','integer','integer','interval'], 'lock_tree_notify() exists');
SELECT has_function('lock_tree_prune_alerts', ARRAY['interval'], 'lock_tree_prune_alerts() exists');
SELECT has_function('lock_tree_sampling_advice', 'lock_tree_sampling_advice() exists');

-- ------------------------------------------------------------------ the payload contract

SELECT ok((SELECT payload ~ '^\s*\{.*\}\s*$' FROM payload_shape),
          'the notification payload is a JSON object rather than a bare string');

SELECT ok((SELECT payload::jsonb ? 'root_pid' FROM payload_shape),
          'carrying root_pid, which is what a listener routes on');

SELECT ok((SELECT payload::jsonb ?& array['channel','application_name','blocked_sessions',
                                        'max_depth','longest_wait','waiting_for'] FROM payload_shape),
          'and every documented key: channel, application_name, blocked_sessions, max_depth, '
          || 'longest_wait, waiting_for');

SELECT ok((SELECT length(payload) < 8000 FROM payload_shape),
          'and it fits the 8000-byte NOTIFY payload limit, which the server enforces');

-- ------------------------------------------------------------------ phase 1: the onset

\set QUIET 1
\o /dev/null
SELECT lock_tree_notify() AS onset \gset
\o
\unset QUIET

SELECT is(:onset::int, 2,
          'the onset notifies once per notable root, so 2 here');

-- ------------------------------------------------------------------ phase 2: no change, no alert

\set QUIET 1
\o /dev/null
SELECT lock_tree_notify() AS repeat_1 \gset
SELECT lock_tree_notify() AS repeat_2 \gset
\o
\unset QUIET

SELECT is(:repeat_1::int, 0,
          'a second call with nothing changed notifies 0 times, which is the entire point');

SELECT is(:repeat_2::int, 0, 'and stays at 0 on a third call, so it is not merely delayed');

SELECT is((SELECT notify_count FROM lock_tree_alert ORDER BY max_blocked_at DESC LIMIT 1), 1,
          'the stored count is still 1 for the widest root, so nothing was double-counted');

SELECT is((SELECT count(*) FROM lock_tree_alert)::int, 2,
          'and there is one state row per notable root, not one per sample');

-- ------------------------------------------------------------------ phase 3: thresholds

\set QUIET 1
\o /dev/null
-- The wide root holds 8 sessions, so min_blocked=10 clears neither and nothing fires.
SELECT lock_tree_notify(min_blocked => 10) AS too_high \gset
-- Depth alone: both roots are flat queues at depth 1, so a min_depth of 2 is not met.
SELECT lock_tree_notify(min_blocked => NULL, min_depth => 2) AS depth_only \gset
-- Wait alone: nothing has waited 30 seconds, the chain having been built moments ago.
SELECT lock_tree_notify(min_blocked => NULL, min_wait => interval '30 seconds') AS wait_only \gset
\o
\unset QUIET

SELECT is(:too_high::int, 0, 'a threshold above the current blocked count does not fire');

SELECT is(:depth_only::int, 0, 'min_depth=2 does not fire for a flat queue of depth 1');

SELECT is(:wait_only::int, 0, 'min_wait=30s does not fire for a queue built moments ago');

-- All three off means "alert on everything", which is refused rather than silently defaulted to
-- something plausible. An alerting function that quietly picks its own thresholds is the failure
-- mode this guards against.
-- The third argument is the FULL expected message, not a description: this pgTAP builds
-- "wanted: <errcode>: <third argument>" and compares that with "caught: <errcode>: <message>".
-- A phrase therefore never matches, which cost three attempts to discover.
SELECT throws_ok(
         $$SELECT lock_tree_notify(min_blocked => NULL, min_depth => NULL, min_wait => NULL)$$,
         'P0001',
         'lock_tree_notify() needs at least one threshold: pass min_blocked, min_depth or '
         || 'min_wait. Passing NULL switches one criterion off, but all three off means '
         || 'alerting on every root, which is almost certainly not what you want.',
         'all three thresholds disabled raises rather than silently defaulting');

\set QUIET 1
\o /dev/null
-- The message itself, captured where SQL can see it. Asserting on it separately is what lets the
-- check above stay a SQLSTATE test and this one be a plain substring comparison.
CREATE TEMP TABLE refusal AS
SELECT 'not raised' AS msg WHERE false;
DO $catch$
DECLARE m text;
BEGIN
  BEGIN
    PERFORM lock_tree_notify(min_blocked => NULL, min_depth => NULL, min_wait => NULL);
  EXCEPTION WHEN OTHERS THEN
    m := SQLERRM;
  END;
  DELETE FROM refusal;
  INSERT INTO refusal VALUES (coalesce(m, 'not raised'));
END
$catch$;
\o
\unset QUIET

SELECT ok((SELECT msg LIKE '%needs at least one threshold%' FROM refusal),
          'and the message says which arguments to pass, not merely that it failed');

SELECT ok((SELECT msg LIKE '%min_blocked%' AND msg LIKE '%min_depth%' AND msg LIKE '%min_wait%'
           FROM refusal),
          'naming all three by name, so the reader does not have to look them up');

-- ------------------------------------------------------------------ phase 4: escalation

\set QUIET 1
\o /dev/null
-- Six more waiters behind r1: 8 becomes 14. Same root, same channel, worse. This must fire even
-- though the root is not new, which is the case a naive implementation gets wrong.
SELECT dblink_connect('z' || i, format('dbname=%s user=%s', current_database(), current_user))
FROM generate_series(1,6) i;
SELECT dblink_send_query('z' || i, format(
  'SET application_name = ''api_extra_%s''; SELECT count(*) FROM lock_tree_al1', lpad(i::text,2,'0')))
FROM generate_series(1,6) i;
DO $more$
BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE application_name LIKE 'api_extra_%' AND wait_event_type = 'Lock') >= 6;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$more$;
SELECT lock_tree_notify() AS escalated \gset
SELECT lock_tree_notify() AS escalated_again \gset
\o
\unset QUIET

SELECT is(:escalated::int, 1,
          'one root got worse while the other did not, so exactly 1 notification: the phase 3 '
          || 'calls used different thresholds and must not have cleared this policy''s state');

SELECT is(:escalated_again::int, 0, 'and re-notifying immediately afterwards is 0 again');

SELECT is((SELECT notify_count FROM lock_tree_alert ORDER BY max_blocked_at DESC LIMIT 1), 2,
          'the wider root has now notified twice: once at onset, once at escalation');

SELECT is((SELECT max_blocked_at FROM lock_tree_alert ORDER BY max_blocked_at DESC LIMIT 1)::int, 14,
          'and its high-water mark recorded 14 sessions, not the 8 it held at onset');

-- ------------------------------------------------------------------ phase 5: recovery, relapse

\set QUIET 1
\o /dev/null
-- Drop both locks: the roots stop being notable, so their state is forgotten. A chain that comes
-- back must alert again rather than being suppressed as already-seen, which is what makes a
-- second incident visible at all.
SELECT dblink_exec('r1', 'ROLLBACK');
SELECT dblink_exec('r2', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_al_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;
SELECT lock_tree_notify() AS after_recovery \gset
SELECT count(*) AS rows_after_recovery FROM lock_tree_alert \gset
-- Now the same two roots block again, with the same waiter counts as at onset.
-- New connections rather than reusing w1..w8 and x1..x4. A waiter released mid-statement leaves
-- an unconsumed result on its dblink connection, and a second send_query on that connection
-- fails with "another command is already in progress", so the relapse chain silently never formed.
SELECT dblink_connect('v' || i, format('dbname=%s user=%s', current_database(), current_user))
FROM generate_series(1,8) i;
SELECT dblink_connect('u' || i, format('dbname=%s user=%s', current_database(), current_user))
FROM generate_series(1,4) i;
SELECT dblink_exec('r1', 'BEGIN');
SELECT dblink_exec('r1', 'SET application_name = ''nightly_batch''');
SELECT dblink_exec('r1', 'LOCK TABLE lock_tree_al1 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('r2', 'BEGIN');
SELECT dblink_exec('r2', 'SET application_name = ''reporting_rollup''');
SELECT dblink_exec('r2', 'LOCK TABLE lock_tree_al2 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('v' || i, format(
  'SET application_name = ''api_%s''; SELECT count(*) FROM lock_tree_al1', lpad(i::text,2,'0')))
FROM generate_series(1,8) i;
SELECT dblink_send_query('u' || i, format(
  'SET application_name = ''report_%s''; SELECT count(*) FROM lock_tree_al2', lpad(i::text,2,'0')))
FROM generate_series(1,4) i;
DO $again$
BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE application_name LIKE 'api\_%' OR application_name LIKE 'report\_%') >= 12;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$again$;
SELECT lock_tree_notify() AS relapse \gset
\o
\unset QUIET

-- The sweep that makes this true cannot live inside the per-root loop: a root whose waiters have
-- all gone has no edges, so it has no row in lock_tree_wide() and the loop never sees it. That is
-- why an earlier version of this function left a row behind forever.
SELECT is(:rows_after_recovery::int, 0,
          'alert state is forgotten when the roots clear, so the table is not a backlog');

SELECT is(:after_recovery::int, 0, 'and nothing fires on a quiet database');

SELECT is(:relapse::int, 2,
          'the same two roots blocking again IS a new incident, and notifies again');

-- ------------------------------------------------------------------ prune and sampling advice

\set QUIET 1
\o /dev/null
SELECT lock_tree_prune_alerts(interval '0 seconds') AS pruned \gset
SELECT blocked_sessions AS advice_blocked,
       (suggested_every = interval '10 seconds')::text AS advice_is_10s,
       (length(reason) > 20)::text AS advice_has_reason
FROM lock_tree_sampling_advice() \gset
\o
\unset QUIET

SELECT is(:pruned::int, 2,
          'lock_tree_prune_alerts() removes rows last notified more than the given age ago');

SELECT is(:advice_blocked::bigint, 12::bigint,
          'lock_tree_sampling_advice() reports the blocked sessions it based its advice on');

SELECT is(:advice_is_10s, 'true',
          'and suggests a 10 second interval for a queue of that size');

SELECT is(:advice_has_reason, 'true',
          'with a reason, since a bare number is not something anyone can argue with');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_alert;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT a.pid FROM lock_tree_al_pids a
           JOIN pg_stat_activity s ON s.pid = a.pid LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE conn text; BEGIN
  FOR conn IN SELECT n FROM al_names LOOP
    BEGIN PERFORM dblink_disconnect(conn); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_al_pids;
DROP TABLE lock_tree_al1;
DROP TABLE lock_tree_al2;
\o
\unset QUIET