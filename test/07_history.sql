-- test/07_history.sql: the sampled history, and what an incident looks like afterwards.
--
-- Everything else in this suite describes the present, which is the one thing this extension
-- cannot do at the moment an operator needs it. An incident is usually noticed after it has
-- ended, and by then pg_stat_activity has moved on. This file covers the part that remembers:
-- taking a sample, keeping it after the incident is over, segmenting it into incidents, and
-- pruning it so the table does not grow without bound.
--
-- The sampling mechanism itself is covered by test/06_cron.sql. This file does not need
-- pg_cron: it calls lock_tree_sample() directly, so the history logic is tested without
-- depending on a background job or a server setting. What is not re-tested here is whether a
-- scheduler can reach it, because test/06_cron.sql already answers that.
--
-- Needs superuser (dblink, to build a real chain) and the dblink contrib module.
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

-- The suite runs against a database that may already hold history from another run, and
-- these tests are about the difference between counts. Start from empty and say so.
TRUNCATE lock_tree_history;

DROP TABLE IF EXISTS lock_tree_ht;
DROP TABLE IF EXISTS lock_tree_ht_pids;
CREATE TABLE lock_tree_ht (id int);
CREATE TABLE lock_tree_ht_pids (name text PRIMARY KEY, pid int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['m','n']) AS n;

INSERT INTO lock_tree_ht_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['m','n']) AS n;

SELECT dblink_exec('m', 'BEGIN');
SELECT dblink_exec('m', 'LOCK TABLE lock_tree_ht IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('n', 'SELECT count(*) FROM lock_tree_ht');

DO $wait$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM lock_tree_ht_pids) AND wait_event_type = 'Lock') = 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

-- Sampling a live chain. Two rows expected: the idle-in-transaction root and the waiter.
SELECT lock_tree_sample() AS live_rows \gset

CREATE TEMP TABLE live AS
SELECT h.sampled_at, h.root_pid, h.depth, h.pid, h.state, h.waiting_for, h.wait_age,
       h.application_name, h.query, h.query_id, p.name
FROM lock_tree_history h
JOIN lock_tree_ht_pids p ON p.pid = h.pid;

-- A sample of a quiet database writes nothing at all, not a row saying nothing was blocked.
-- This is the property that makes the table affordable to keep: an idle server costs one
-- SELECT and no storage.
SELECT pg_terminate_backend((SELECT pid FROM lock_tree_ht_pids WHERE name = 'n'));
DO $gone$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree_ht_pids p
                          JOIN pg_stat_activity a ON a.pid = p.pid
                          WHERE a.wait_event_type = 'Lock');
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$gone$;

-- The root still holds its lock, so the tree is empty even though m is connected. Roll it
-- back too, then sample again.
SELECT dblink_exec('m', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_ht_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;
SELECT lock_tree_sample() AS quiet_rows \gset
\o
\unset QUIET

SELECT plan(35);

SELECT has_table('lock_tree_history', 'lock_tree_history table exists');
SELECT has_function('lock_tree_sample', 'lock_tree_sample() exists');
SELECT has_function('lock_tree_prune', ARRAY['interval'], 'lock_tree_prune(interval) exists');
SELECT has_function('lock_tree_incidents', ARRAY['interval','interval'],
                    'lock_tree_incidents(interval, interval) exists since 1.1.0');

-- ------------------------------------------------------------------ the sample itself

SELECT is(:live_rows::int, 2,
          'sampling a two-session chain writes one row per session in it');

SELECT is((SELECT count(*) FROM live)::int, 2, 'both sessions of the chain were captured');

SELECT is((SELECT depth FROM live WHERE pid = (SELECT pid FROM lock_tree_ht_pids WHERE name = 'm')),
          0, 'the captured root is at depth 0, as it was live');
SELECT is((SELECT depth FROM live WHERE pid = (SELECT pid FROM lock_tree_ht_pids WHERE name = 'n')),
          1, 'and the captured waiter is at depth 1');

-- Schema-qualified, because lock_tree_sample pins search_path to pg_catalog and regclass
-- only omits the schema when it is visible. That is the better of the two behaviours for a
-- record that outlives the session which created it, but it is a difference from the live
-- view and worth pinning rather than rediscovering.
-- .*  for the optional schema, after two attempts that did not work: \. needs the backslash
-- to survive a SQL string literal and pgTAP together, and [(] is not treated as a literal
-- parenthesis in a POSIX ARE, so the engine reported unbalanced parentheses. This asks the
-- question that matters, which is the lock mode and the relation, without pinning whether the
-- schema is spelled out.
SELECT matches((SELECT waiting_for FROM live WHERE pid = (SELECT pid FROM lock_tree_ht_pids WHERE name = 'n')),
               '^AccessShareLock on .*lock_tree_ht$',
               'the sample keeps what the waiter was waiting for, not just who');

SELECT is(:quiet_rows::int, 0,
          'sampling a quiet database writes 0 rows rather than one row saying nothing happened');

-- The reason clock_timestamp() is used and not now(): now() is the transaction timestamp, so
-- every row from one sample would share an instant and the incident grouping below, which
-- keys on sampled_at, would treat the whole sample as a single point in time.
SELECT is((SELECT count(DISTINCT sampled_at) FROM live)::int, 1,
          'one sample puts all its rows at one instant, so the chain is a single point');

-- ------------------------------------------------------------------ history outlives the tree

\set QUIET 1
\o /dev/null
-- Backdate two samples so they are far enough apart to be two incidents under the default
-- five-minute gap, and close enough to be one under a fifteen-minute gap. That makes the
-- threshold a parameter demonstrably worth having rather than a constant that happens to work.
-- Three samples of a three-session chain for the first incident, and two for the second.
-- Each sample carries all three depths at ONE sampled_at, which is the whole point: rows that
-- share an instant are one observation of one tree. Inserting one row per timestamp, which is
-- what the first draft of this fixture did, makes every sample look like one session and
-- reduces peak_sessions to 1 throughout.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age, application_name)
SELECT v.t, 900, d, 900 + d, 'idle in transaction', make_interval(secs => d * 30), 'nightly_batch'
FROM (VALUES
  (now() - interval '40 min', 0), (now() - interval '40 min', 1), (now() - interval '40 min', 2),
  (now() - interval '38 min', 0), (now() - interval '38 min', 1), (now() - interval '38 min', 2),
  (now() - interval '36 min', 0), (now() - interval '36 min', 1), (now() - interval '36 min', 2),
  (now() - interval '5 min',  0), (now() - interval '5 min',  1),
  (now() - interval '4 min',  0), (now() - interval '4 min',  1)
) AS v(t, d);
\o
\unset QUIET

-- A second sample of the same incident, carrying a session that never named itself and a root
-- whose object is unresolvable. Two minutes after the last existing sample, so the default
-- five-minute gap folds these rows into the incident that starts four minutes ago rather than
-- opening a third one: the incident count stays at two and every count assertion above and
-- below still describes the same two incidents.
--
-- This is the fixture for the NULL asymmetry in the array columns, which is the one behaviour
-- in lock_tree_incidents() that nothing asserted before. `applications` keeps a NULL element,
-- because a session with no application_name is a real thing worth reporting. `root_objects`
-- drops its NULLs, because there a NULL means a prepared root whose object could not be
-- resolved, and an empty element would be indistinguishable from an empty string.
--
-- The depth-0 row here is the only row in this file with a non-NULL root_object, so
-- root_objects is a one-element array that is meaningfully free of NULLs rather than a NULL
-- array where "no NULLs" would be true for free.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, root_object)
VALUES
  (now() - interval '2 min', 900, 0, 900, 'idle in transaction', interval '90 seconds',
   NULL, 'pg_accounts'),
  (now() - interval '2 min', 900, 1, 901, 'idle in transaction', interval '60 seconds',
   'nightly_batch', NULL);

SELECT is((SELECT count(*) FROM lock_tree)::int, 0,
          'the live tree is empty, because the incident it described is over');

SELECT is((SELECT count(*) FROM lock_tree_history)::int, 17,
          'and the sampled history still holds every row: 2 from the live sample, 13 backdated, '
          || 'plus the 2 that carry the NULL case below');

-- ------------------------------------------------------------------ incident segmentation

SELECT is((SELECT count(*) FROM lock_tree_incidents())::int, 2,
          'history with a gap longer than 5 minutes is reported as two incidents');

SELECT is((SELECT count(*) FROM lock_tree_incidents(interval '40 minutes'))::int, 1,
          'and the same history is one incident when the threshold exceeds the gap between them');

SELECT is((SELECT peak_sessions FROM lock_tree_incidents() ORDER BY started_at LIMIT 1)::int, 3,
          'the first incident peaked at 3 sessions blocked');

SELECT is((SELECT peak_depth FROM lock_tree_incidents() ORDER BY started_at LIMIT 1)::int, 2,
          'and reached a chain depth of 2');

SELECT is((SELECT longest_wait FROM lock_tree_incidents() ORDER BY started_at LIMIT 1),
          interval '1 minute', 'the longest wait seen during the first incident is reported');

SELECT is((SELECT roots FROM lock_tree_incidents() ORDER BY started_at LIMIT 1),
          ARRAY[900]::int[], 'and the root pid that caused it is named');

-- ------------------------------------------------------------------ NULLs in the array columns
--
-- Four assertions, and the last one is what makes the first three mean anything. Each is a
-- count of NULL elements rather than an equality against a literal array, because an array
-- containing a NULL cannot be compared with = and a test written that way would either error
-- or quietly pass. Counting through unnest handles the NULL element as the value it is.

-- Aggregated over every incident rather than reading one of them. The recent incident also
-- contains the live sample, whose application_name is whatever this session is called, so
-- reading a single incident would make the named-application count a property of the test
-- runner rather than of the function. The total number of NULL elements is not.
--
-- Each is a count of NULL elements rather than an equality against a literal array, because an
-- array containing a NULL cannot be compared with =, and a test written that way would either
-- error or quietly pass. Counting through unnest treats the NULL as the value it is.

SELECT is((SELECT count(*) FROM lock_tree_incidents() i, unnest(i.applications) a
            WHERE a IS NULL)::int, 1,
          'applications keeps exactly one NULL element across the history, because a session '
          || 'with no application_name is worth reporting and array_agg does not skip it');

SELECT is((SELECT count(*) FROM lock_tree_incidents() i
            WHERE i.applications @> ARRAY['nightly_batch']::text[])::int, 2,
          'both incidents still name nightly_batch, so the NULL was added alongside the named '
          || 'values rather than in place of one');

SELECT is((SELECT count(*) FROM lock_tree_incidents() i, unnest(i.root_objects) o
            WHERE o IS NULL)::int, 0,
          'root_objects carries no NULL element anywhere, even though most rows in the same '
          || 'incident have a NULL root_object');

SELECT is((SELECT sum(cardinality(i.root_objects))::int FROM lock_tree_incidents() i), 1,
          'and it does still carry the one object it could resolve, so the check above is not '
          || 'passing on an empty array');

SELECT is((SELECT count(*) FROM lock_tree_incidents() i, unnest(i.applications) a
            WHERE a IS NULL)::int - 1, 0,
          'CONTROL: subtracting the one NULL this file planted leaves zero, so the first '
          || 'assertion is pinning this fixture rather than something every incident does');

-- ------------------------------------------------------------------ the window, added in 1.1.0
--
-- The fixture above holds samples at 40, 38, 36, 5, 4 and 2 minutes ago. That makes the assertions below
-- exact rather than approximate: a 10 minute window keeps the 5, 4 and 2 minute samples and drops the
-- three that are 36 minutes and older, so the older incident disappears entirely.
--
-- since defaults to NULL rather than to a week on purpose. NULL means the whole retained history, which
-- is what this function did in every release before 1.1.0, so a caller who never passes it sees no
-- change at all. A default of '7 days' would have matched its neighbours and would have quietly changed
-- what every existing call returned on any database holding more than a week, which is a behaviour
-- change dressed as an additive one.

SELECT is((SELECT count(*) FROM lock_tree_incidents(since => NULL))::int, 2,
          'since => NULL is the whole retained history, which is what the no-argument call means');

SELECT is((SELECT count(*) FROM lock_tree_incidents(since => interval '10 minutes'))::int, 1,
          'a 10 minute window keeps the recent incident and drops the one 36 minutes old');

SELECT is((SELECT sum(samples) FROM lock_tree_incidents(since => interval '1 minute'))::int, 1,
          'a 1 minute window sees only the sample this file took of the live tree, and nothing older');

SELECT is((SELECT count(*) FROM lock_tree_incidents(since => interval '-1 hour'))::int, 0,
          'a window containing no sample at all returns no rows rather than erroring');

SELECT is((SELECT count(*) FROM lock_tree_incidents(interval '40 minutes',
                                                    interval '10 minutes'))::int, 1,
          'both arguments positionally: the gap threshold still works with a window beside it');

SELECT is((SELECT count(*) FROM lock_tree_incidents(interval '40 minutes'))::int, 1,
          'and a one-argument positional call still binds to max_gap, which is why since goes second');

-- ------------------------------------------------------------------ pruning

-- Each prune is asserted on before the next one runs. Doing both in one quiet block first,
-- as this did originally, meant "the rows are still there" was checked after the table had
-- already been emptied, which is a test that passes for the wrong reason or fails for a
-- confusing one depending on the counts.
\set QUIET 1
\o /dev/null
-- A retention window newer than everything in the table removes nothing.
SELECT lock_tree_prune(interval '1 day') AS pruned_recent \gset
\o
\unset QUIET

SELECT is(:pruned_recent::int, 0,
          'pruning with a window newer than the data removes nothing');

SELECT is((SELECT count(*) FROM lock_tree_history)::int, 17,
          'and the rows are all still there');

\set QUIET 1
\o /dev/null
-- Zero seconds removes everything: every sampled_at is at or before the statement that wrote
-- it, so every row is strictly older than now. One second was the first choice and it pruned
-- only the 13 backdated rows, because the two from the live sample were seconds old at that
-- point, and the two carrying the NULL case are the same age as the newest backdated sample.
-- The window has to be older than the newest row, and the newest row is always the one
-- just taken.
SELECT lock_tree_prune(interval '0 seconds') AS pruned_all \gset
\o
\unset QUIET

SELECT is(:pruned_all::int, 17,
          'pruning with a window older than the data removes all of it');

SELECT is((SELECT count(*) FROM lock_tree_history)::int, 0, 'leaving the table empty');

SELECT is((SELECT count(*) FROM lock_tree_incidents())::int, 0,
          'and empty history reports no incidents rather than erroring');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
-- Only the session still alive. The waiter was terminated earlier to release the tree, so
-- terminating it again emits "PID N is not a PostgreSQL backend process" as a warning and
-- returns false. Harmless, but two warnings per run is noise that trains people to ignore
-- warnings, and a real one would then go unnoticed.
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT h.pid FROM lock_tree_ht_pids h
           JOIN pg_stat_activity a ON a.pid = h.pid LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['m','n'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_ht_pids;
DROP TABLE lock_tree_ht;
TRUNCATE lock_tree_history;
\o
\unset QUIET