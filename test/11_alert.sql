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

SELECT plan(55);

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


  -- ------------------------------------------------------------------ the shared contract keys
  --
  -- Added in 1.1.11: pg_incident_watch, the umbrella this extension is part of, wants every tool's
  -- NOTIFY payload to carry `tool`, `subject` and `sampled_at` so one listener can route on them.
  --
  -- These read the function bodies rather than a replica, because the replica above is hand-written
  -- and would pass unchanged if the function dropped a key. That is the same trap the shape
  -- assertions above fall into, and it is why these exist: a test that cannot fail is decoration.
  SELECT ok((SELECT prosrc LIKE '%''tool'',%pg_lock_tree%' FROM pg_proc WHERE proname='lock_tree_notify'),
            'lock_tree_notify() builds a payload carrying tool: pg_lock_tree');

  SELECT ok((SELECT prosrc LIKE '%''subject'',%' FROM pg_proc WHERE proname='lock_tree_notify'),
            'and carrying subject, the key a listener uses to pair an onset with its escalation');

  SELECT ok((SELECT prosrc LIKE '%''sampled_at'',%' FROM pg_proc WHERE proname='lock_tree_notify'),
            'and carrying sampled_at, so a consumer can order messages from two tools against each other');

  -- The cleared payload needs the same keys, and needs subject built the SAME way. A cleared message
  -- whose subject does not match its onset is worse than no cleared message, because a listener
  -- pairing on subject would silently drop it.
  SELECT ok((SELECT prosrc LIKE '%''tool'',%pg_lock_tree%'
             FROM pg_proc WHERE proname='lock_tree_notify_resolved'),
            'lock_tree_notify_resolved() carries the same tool key');

  -- position() rather than LIKE. A LIKE pattern for this needs the wildcards interleaved with literal
  -- quotes, and the first version of these two assertions failed against a function that demonstrably
  -- contains the expression. A test that fails for a reason other than the thing it names is worse
  -- than no test, because it trains you to ignore it.
  SELECT ok((SELECT position('coalesce(nullif(gone.root_object, ''''), ''pid '' || gone.root_pid)'
                          in prosrc) > 0
             FROM pg_proc WHERE proname='lock_tree_notify_resolved'),
            'and builds subject from the swept row with the same expression the onset uses, so the two pair');

  SELECT ok((SELECT position('coalesce(nullif(r.root_object, ''''), ''pid '' || r.root_pid)'
                          in prosrc) > 0
             FROM pg_proc WHERE proname='lock_tree_notify'),
            'which is that the onset expression is the same coalesce over the same two fields');

  -- The contract defines `escalated`; this extension does not send it, and says so rather than
  -- emitting a value it does not mean.
  SELECT ok((SELECT prosrc NOT LIKE '%escalated%' FROM pg_proc WHERE proname='lock_tree_notify'),
            'and it sends no escalated event, which the contract permits: it still uses alerting for '
            || 'both onset and escalation, and claiming otherwise would be a lie');

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
    -- Wait for the waiters to be BLOCKED, not merely present. A dblink session appears in
    -- pg_stat_activity the moment it connects, which is before its SELECT has reached the lock, so
    -- counting sessions can exit this loop with none of them waiting yet. lock_tree_notify() then
    -- sees one notable root instead of two and returns 1 where this test wants 2. That is a race,
    -- not a defect in the sweep, and it is the only loop in this suite that waited on presence:
    -- every other one joins pg_stat_activity on wait_event_type = 'Lock', including the escalation
    -- loop above, which is why that one never flaked.
    --
    -- Both groups are counted separately rather than as one OR, so 12 blocked sessions is not
    -- satisfied by 12 waiters behind a single root.
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE wait_event_type = 'Lock' AND application_name LIKE 'api\_%') >= 8
         AND (SELECT count(*) FROM pg_stat_activity
               WHERE wait_event_type = 'Lock' AND application_name LIKE 'report\_%') >= 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$again$;
-- Captured for the precondition assertion below, so a wait that times out says so instead of
-- showing up as a confusing "have: 1 want: 2" from the sweep.
SELECT (SELECT count(*) FROM pg_stat_activity
         WHERE wait_event_type = 'Lock' AND application_name LIKE 'api\_%') AS relapse_api,
       (SELECT count(*) FROM pg_stat_activity
         WHERE wait_event_type = 'Lock' AND application_name LIKE 'report\_%') AS relapse_report
\gset
SELECT lock_tree_notify() AS relapse \gset
\o
\unset QUIET

SELECT is(:relapse_api::int >= 8 AND :relapse_report::int >= 4, true,
          'precondition: all twelve relapse waiters are blocked on a lock before the sweep runs');

-- The sweep that makes this true cannot live inside the per-root loop: a root whose waiters have
-- all gone has no edges, so it has no row in lock_tree_wide() and the loop never sees it. That is
-- why an earlier version of this function left a row behind forever.
SELECT is(:rows_after_recovery::int, 0,
          'alert state is forgotten when the roots clear, so the table is not a backlog');

SELECT is(:after_recovery::int, 0, 'and nothing fires on a quiet database');

SELECT is(:relapse::int, 2,
          'the same two roots blocking again IS a new incident, and notifies again');

-- ------------------------------------------------------------------ phase 6: escalation by age

-- Everything above escalates on WIDTH or DEPTH. Neither moves here: one root, one waiter, and it
-- stays that way. The only thing that changes is how long the waiter has been waiting, so every
-- notification after the onset can only have come from the age rule. That isolation is the point:
-- a test where the queue is also growing proves nothing about which rule fired.
--
-- The waits here are real and measured in whole seconds, because the view truncates wait_age to
-- date_trunc('second', ...). A sub-second wait reads as 0, and that case caught a bug in this
-- function on the first run; see the greatest() in the escalation comparison.
\set QUIET 1
\o /dev/null
-- Clear the phase 5 chain first, or its root is still notable and would escalate on age during the
-- sleeps below, and every count would be about two incidents rather than one.
SELECT dblink_exec('r1', 'ROLLBACK');
SELECT dblink_exec('r2', 'ROLLBACK');
DO $clear$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_al_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$clear$;

DROP TABLE IF EXISTS lock_tree_al_steady;
CREATE TABLE lock_tree_al_steady (id int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['sa_h','sa_w']) n;
CREATE TEMP TABLE sa_pids AS
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int)) AS pid
FROM unnest(ARRAY['sa_h','sa_w']) AS s(n);
SELECT dblink_exec('sa_h', 'BEGIN');
SELECT dblink_exec('sa_h', 'SET application_name = ''steady_batch''');
SELECT dblink_exec('sa_h', 'LOCK TABLE lock_tree_al_steady IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('sa_w',
                         'SET application_name = ''api_waiter''; SELECT count(*) FROM lock_tree_al_steady');
DO $swait$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a JOIN sa_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') = 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$swait$;
-- Long enough that wait_age is at least a second.
SELECT pg_sleep(1.5);
-- One second rather than the default thirty: this file has to finish, and what is under test is the
-- shape of the escalation rather than the particular interval.
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => interval '1 second') AS age_onset \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => interval '1 second') AS age_unchanged \gset
SELECT pg_sleep(1.5);
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => interval '1 second') AS age_doubled \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => interval '1 second') AS age_again \gset
\o
\set QUIET 0

-- Establish that width and depth did not move, or the assertions below prove nothing.
SELECT is((SELECT blocked_sessions FROM lock_tree_wide()), 1::bigint,
          'the steady chain blocks exactly one session, unchanged throughout');

SELECT is((SELECT max_depth FROM lock_tree_wide()), 1,
          'and is one deep, unchanged throughout');

SELECT ok((SELECT longest_wait >= interval '1 second' FROM lock_tree_wide()),
          'so the only thing that can have escalated this is the wait, which has grown past a second');

SELECT is(:age_onset::int, 1, 'the onset still fires exactly once');

SELECT is(:age_unchanged::int, 0,
          'and a second call with nothing changed is still 0: age alone is not enough, it has to '
          || 'have doubled');

SELECT is(:age_doubled::int, 1,
          'once the wait has doubled the function fires again, which is the whole point of 0.9');

SELECT is(:age_again::int, 0,
          'and then falls silent again, rather than firing once per sample for the rest of the '
          || 'incident');

-- Scoped to this chain's root: lock_tree_notify() sweeps only the policy it was called with, and
-- that is deliberate, so the table still holds the default-policy rows from phases 1 to 5.
SELECT is((SELECT notify_count FROM lock_tree_alert a
           WHERE a.root_pid = (SELECT root_pid FROM lock_tree WHERE depth = 0)), 2,
          'two notifications in total: the onset and the one escalation');

-- The three high-water marks are recorded independently, which is what lets an incident that grows
-- in only one dimension escalate on that dimension alone.
SELECT is((SELECT max_blocked_at FROM lock_tree_alert a
           WHERE a.root_pid = (SELECT root_pid FROM lock_tree WHERE depth = 0)), 1::bigint,
          'the blocked high-water mark never moved, since the queue never grew');

SELECT is((SELECT max_depth_at FROM lock_tree_alert a
           WHERE a.root_pid = (SELECT root_pid FROM lock_tree WHERE depth = 0)), 1,
          'nor did the depth mark');

SELECT ok((SELECT max_waited_at >= interval '1 second' FROM lock_tree_alert a
            WHERE a.root_pid = (SELECT root_pid FROM lock_tree WHERE depth = 0)),
          'while the wait mark did, and is stored rather than recomputed on every sample');

-- The gate. min_wait => NULL means "do not page me on wait age", and this is the case that stopped
-- the first attempt from being a bare parameter: honouring the switch is what keeps the channel
-- worth reading.
\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_alert;
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS gate1 \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS gate2 \gset
SELECT pg_sleep(1.5);
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS gate3 \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS gate4 \gset
\o
\set QUIET 0

SELECT is(:gate1::int, 1, 'with min_wait off the onset still fires, because it is notable by width');

SELECT is(:gate2::int, 0, 'and a repeat is silent');

SELECT ok((SELECT longest_wait >= interval '2 seconds' FROM lock_tree_wide()),
          'the wait has grown well past any threshold that would otherwise have applied');

SELECT is(:gate3::int, 0,
          'yet it still does not fire: an operator who passed min_wait => NULL asked not to be '
          || 'paged on wait age');

SELECT is(:gate4::int, 0, 'and stays silent however much longer the wait goes on');

SELECT is((SELECT max_waited_at FROM lock_tree_alert a
           WHERE a.root_pid = (SELECT root_pid FROM lock_tree WHERE depth = 0)), interval '0',
          'with no wait recorded, because there was no wait criterion to escalate against');

-- ------------------------------------------------------------------ prune and sampling advice

\set QUIET 1
\o /dev/null
SELECT lock_tree_prune_alerts(interval '0 seconds') AS pruned \gset
SELECT blocked_sessions AS advice_blocked,
       roots AS advice_roots,
       (suggested_every = interval '5 seconds')::text AS advice_is_5s,
       (length(reason) > 20)::text AS advice_has_reason
FROM lock_tree_sampling_advice() \gset
\o
\unset QUIET

SELECT is(:pruned::int, 1,
          'lock_tree_prune_alerts() removes rows last notified more than the given age ago, which '
          || 'is the single row phase 6 left: the gate section truncated the table');

SELECT is(:advice_blocked::bigint, 1::bigint,
          'lock_tree_sampling_advice() reports the blocked sessions it based its advice on, which '
          || 'here is the one steady-chain waiter still standing');

SELECT is(:advice_roots::bigint, 1::bigint,
          'and the root count beside it, so the advice can be traced back to what it saw');

SELECT is(:advice_is_5s, 'true',
          'a queue of one session falls in the under-10 band and gets a 5 second interval');

SELECT is(:advice_has_reason, 'true',
          'with a reason, since a bare number is not something anyone can argue with');

\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(pid) FROM sa_pids;
DO $sab$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM (VALUES ('sa_h'), ('sa_w')) AS t(n) LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$sab$;
DROP TABLE lock_tree_al_steady;
\o
\set QUIET 0

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