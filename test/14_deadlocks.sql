-- test/14_deadlocks.sql: the deadlock counter, sampled, and the advice that reads history.
--
-- Two things here that no earlier file covers.
--
-- DEADLOCKS. The extension could see a deadlock happening and had nothing to say about it.
-- pg_stat_database.deadlocks has been there since PostgreSQL 13, so it is available on every version
-- supported here; checked rather than assumed, since the version it was added is the sort of thing
-- worth being wrong about. The counter names no participants. The two statements involved are in
-- the server log and nothing in SQL exposes them, so this does not pretend otherwise: what it
-- records is WHEN, which is the half that makes the log worth reading.
--
-- The counter is sampled into its own table rather than onto lock_tree_history, and that is the
-- point rather than tidiness. lock_tree_history only has rows while something is blocked, and
-- PostgreSQL resolves a deadlock by killing one participant, so by the time a sampler runs the tree
-- is empty and there is no history row to hang a counter on. The sampling assertion below is
-- written to make exactly that visible: a sample taken on a quiet tree still records the counter.
--
-- The end-to-end case, a REAL deadlock moving the counter between two samples, is in
-- scenarios/s6_deadlock.sql rather than here. It was attempted here first and does not work in a
-- single psql session: the deadlock is built from dblink connections belonging to the session that
-- is also sampling, and the two interfere. Doing it in a separate process works every time, which
-- is what the scenario does, and a test that only passes when nothing else is running is not a
-- test.
--
-- ADVICE FROM HISTORY. lock_tree_sampling_advice() used to size the interval from the queue at the
-- instant it was called, which meant a cron entry at 3am on a quiet Sunday recommended the finest
-- interval for a database that spends every weekday morning with four hundred sessions waiting. It
-- now reads the peak out of the history.
--
-- Needs superuser (dblink), and the dblink contrib module.
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

TRUNCATE lock_tree_history;
TRUNCATE lock_tree_deadlock;
-- Output has to be on again before plan() and the schema assertions. They were left inside the
-- quiet region at first, which runs them and emits nothing: pgTAP still counts them, so the TAP
-- stream started at "ok 5" and pg_prove rejected the whole file as out of sequence.
\o
\unset QUIET

SELECT plan(29);

SELECT has_table('lock_tree_deadlock', 'lock_tree_deadlock table exists');

SELECT has_function('lock_tree_deadlocks', ARRAY['interval'], 'lock_tree_deadlocks(interval) exists');

SELECT has_column('lock_tree_deadlock', 'delta', 'it records how far the counter moved');

SELECT has_column('lock_tree_deadlock', 'counter_reset',
                  'and whether the counter went backwards, which is what pg_stat_reset_shared does');

-- ---------------------------------------------------------------- sampling the counter

-- The point of a separate table, stated as an assertion: a sample on a quiet tree records nothing
-- for the history and still records the counter.
\set QUIET 1
\o /dev/null
SELECT lock_tree_sample() AS quiet_rows \gset
SELECT count(*) AS deadlock_rows FROM lock_tree_deadlock \gset
SELECT deadlocks AS recorded FROM lock_tree_deadlock ORDER BY sampled_at DESC LIMIT 1 \gset
SELECT deadlocks AS actual FROM pg_stat_database WHERE datname = current_database() \gset
\o
\set QUIET 0

SELECT is(:quiet_rows::bigint, 0::bigint,
          'a sample on a quiet tree writes no history rows, because there is nothing in the tree');

SELECT is(:deadlock_rows::int, 1,
          'and writes exactly one deadlock row anyway, which is the case that would otherwise be '
          || 'invisible');

SELECT is(:recorded::bigint, :actual::bigint,
          'recording the live pg_stat_database.deadlocks value, so the sample reads the same '
          || 'counter an operator would read');

\set QUIET 1
\o /dev/null
SELECT lock_tree_sample() AS second_rows \gset
SELECT count(*) AS rows_now FROM lock_tree_deadlock \gset
SELECT count(*) AS moves FROM lock_tree_deadlock WHERE delta > 0 \gset
\o
\set QUIET 0

SELECT is(:rows_now::int, 2, 'a second sample adds a second row');

SELECT is(:moves::int, 0,
          'with no move recorded, because the counter did not move: a delta of 0 is the correct '
          || 'answer and not an absence of one');

SELECT is((SELECT delta FROM lock_tree_deadlock ORDER BY sampled_at LIMIT 1), 0::bigint,
          'and the first row always reports 0, because there is no previous row to subtract');

-- The arithmetic, written directly. Provoking a real reset would mean running
-- pg_stat_reset_shared and throwing away everyone's statistics to prove a subtraction, and
-- provoking a real move would mean a timing-dependent deadlock, which belongs in a scenario.
\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_deadlock;
INSERT INTO lock_tree_deadlock (sampled_at, deadlocks, delta, counter_reset) VALUES
  (clock_timestamp() - interval '4 hours', 500, 0,  false),
  (clock_timestamp() - interval '3 hours', 504, 4,  false),
  (clock_timestamp() - interval '2 hours',   0, 0,  true),
  (clock_timestamp() - interval '1 hour',     3, 3,  false);
SELECT count(*) AS reported FROM lock_tree_deadlocks() \gset
SELECT coalesce(sum(delta) FILTER (WHERE NOT counter_reset), 0) AS win_total FROM lock_tree_deadlocks() \gset
SELECT count(*) AS narrow FROM lock_tree_deadlocks(interval '90 minutes') \gset
SELECT count(*) AS everything FROM lock_tree_deadlocks(interval '10 days') \gset
\o
\set QUIET 0

SELECT is((SELECT count(*) FROM lock_tree_deadlock WHERE delta > 0), 2::bigint,
          'two of the four samples recorded a move');

SELECT is(:reported::int, 3,
          'lock_tree_deadlocks() reports the two moves AND the reset, because a changed baseline is '
          || 'itself something a reader needs to know about');

SELECT is(:win_total::bigint, 7::bigint,
          'and the window total sums only the deltas after the reset, so it is 4 + 3 rather than a '
          || 'negative gap pretending to be a number of deadlocks');

-- The -1h sample is inside a 90 minute window and its delta was 3, so it is correctly reported.
-- The point is that the two samples before it, including the reset, are excluded.
SELECT is(:narrow::int, 1,
          'a narrow window reports only the sample inside it, and the reset outside it is gone, so '
          || 'the window is applied before the rows are chosen');

SELECT is(:everything::int, 3, 'a window covering them all reports all three');

SELECT is((SELECT delta FROM lock_tree_deadlock WHERE counter_reset), 0::bigint,
          'a reset row carries a delta of 0 rather than -500, since a falling counter is not '
          || 'negative deadlocks');

-- ---------------------------------------------------------------- advice from history

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_history;
-- A history that peaked at 450 sessions an hour ago and has been quiet since. This is the shape
-- that made the old advice wrong: the queue at the moment of the call is zero, so 0.9 recommended
-- the finest interval for a table that has to carry 450 rows a sample.
-- now(), NOT clock_timestamp(), and this is not a style preference.
--
-- clock_timestamp() is volatile and is evaluated once per ROW, so this insert would give all 450
-- rows a different sampled_at a few microseconds apart. The advice groups the history by
-- sampled_at to find the widest sample, and 450 groups of one session each has a peak of 1: the
-- fixture would quietly describe a database with no queue at all.
--
-- This is the same trap that made lock_tree_sample() record a different sampled_at per row in 0.4,
-- which silently capped peak_sessions at 1 and was found only by an assertion that expected a
-- larger number. It is worth writing down a second time, because it looks like a harmless choice of
-- clock function and it is not: any per-row timestamp in this table destroys the only thing the
-- history is for.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state)
SELECT now() - interval '1 hour', 1000 + g, 0, 1000 + g, 'idle in transaction'
FROM generate_series(1, 450) g;
SELECT blocked_sessions AS a_blocked, observed_peak AS a_peak, live_blocked AS a_live,
       (suggested_every = interval '30 seconds')::text AS a_is_30s,
       (look_back = interval '7 days')::text AS a_window
FROM lock_tree_sampling_advice() \gset
SELECT blocked_sessions AS n_blocked, observed_peak AS n_peak
FROM lock_tree_sampling_advice(since => interval '1 minute') \gset
TRUNCATE lock_tree_history;
SELECT blocked_sessions AS q_blocked, observed_peak AS q_peak, live_blocked AS q_live,
       (suggested_every = interval '5 seconds')::text AS q_is_5s
FROM lock_tree_sampling_advice() \gset
\o
\set QUIET 0

SELECT has_function('lock_tree_sampling_advice', ARRAY['interval'],
                    'lock_tree_sampling_advice() takes a window, so the peak can be bounded');

SELECT is(:a_live::bigint, 0::bigint, 'nothing is blocked right now');

SELECT is(:a_peak::bigint, 450::bigint, 'but the history peaked at 450 inside the window');

SELECT is(:a_blocked::bigint, 450::bigint,
          'and the advice is sized on 450, not on the zero it would have reported in 0.9');

SELECT is(:a_is_30s, 'true',
          'giving the widest interval, because 450 sessions a sample is the table dominating '
          || 'everything else');

SELECT is(:a_window, 'true', 'and the window it used is reported back, so the advice is traceable');

SELECT is(:n_blocked::bigint, 0::bigint,
          'a window that excludes the peak returns to zero, so the peak really does come from the '
          || 'history');

SELECT is(:q_peak::bigint, 0::bigint, 'and an empty history has no peak');

SELECT is(:q_live::bigint, 0::bigint, 'nor a live queue');

SELECT is(:q_is_5s, 'true',
          'so the finest interval comes back, for a database with nothing to carry');

-- ---------------------------------------------------------------- prune

\set QUIET 1
\o /dev/null
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state)
VALUES (clock_timestamp() - interval '9 days', 1, 0, 1, 'idle in transaction'),
       (clock_timestamp() - interval '9 days', 1, 1, 2, 'active');
INSERT INTO lock_tree_deadlock (sampled_at, deadlocks, delta)
VALUES (clock_timestamp() - interval '9 days', 0, 0);
SELECT lock_tree_prune(interval '7 days') AS pruned \gset
SELECT count(*) AS old_deadlock_rows FROM lock_tree_deadlock
 WHERE sampled_at < clock_timestamp() - interval '7 days' \gset
SELECT count(*) AS kept_recent FROM lock_tree_deadlock \gset
\o
\set QUIET 0

SELECT is(:pruned::bigint, 2::bigint,
          'lock_tree_prune() reports the history rows it removed');

SELECT is(:old_deadlock_rows::int, 0,
          'and the deadlock samples went with them, even though they are not in the count, so an '
          || 'unpruned table cannot grow by one row per sample forever');

SELECT is(:kept_recent::int, 4, 'while the recent samples are left alone');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_deadlock;
TRUNCATE lock_tree_history;
\o
\set QUIET 0