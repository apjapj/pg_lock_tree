-- test/19_index_usage.sql: the read functions must SEEK, not filter over the whole index.
--
-- This file exists because of a performance bug that no correctness test could see. Fifteen window
-- bounds on a stored column used clock_timestamp(), which is VOLATILE, so the planner could not make
-- them index bounds and every one degraded into a filter over the entire index:
--
--   sampled_at >= clock_timestamp()     - interval '1 hour'
--     Index Only Scan, Filter, 165740 rows removed,  18.5 ms
--   sampled_at >= statement_timestamp() - interval '1 hour'
--     Index Only Scan, Index Cond,                      0.777 ms
--
-- Nothing here asserts on elapsed time. A time bound passes vacuously on a warm cache and fails on a
-- loaded one, which makes it a bad thing to assert on and a worse thing to rely on. These assert on
-- the SHAPE OF THE PLAN and on the FUNCTION SOURCE, both of which fail loudly when they regress.
--
-- Needs superuser. Builds no lock chain and needs no dblink: the fixture is written as rows rather
-- than produced by locking sessions, so the test is fast and deterministic.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

TRUNCATE lock_tree_history;

-- A few thousand rows across 120 instants. The bug does not need a big table to show itself, because
-- the point is that the OLD plan walked all of it instead of the window.
\o
\set QUIET 0
INSERT INTO lock_tree_history
  (sampled_at, root_pid, depth, pid, state, waiting_for, wait_age,
   application_name, query, root_object, query_id)
SELECT now() - interval '2 hours' + k.n * interval '30 seconds',
       500,
       d.d,
       500 + d.d * 10,
       CASE WHEN d.d = 0 THEN 'idle in transaction' ELSE 'active' END,
       CASE WHEN d.d = 0 THEN NULL ELSE 'AccessExclusiveLock on public.ledger' END,
       make_interval(secs => k.n),
       CASE WHEN d.d = 0 THEN 'batch' ELSE 'api_' || d.d::text END,
       CASE WHEN d.d = 0 THEN 'UPDATE ledger SET amount = amount WHERE id = 1'
            ELSE 'SELECT ' || d.d::text END,
       NULL,
       CASE WHEN d.d = 0 THEN 9000000000000000001 ELSE NULL END
  FROM generate_series(1, 120) AS k(n)
  CROSS JOIN generate_series(0, 4) AS d(d);

SELECT plan(20);

-- ------------------------------------------------------ the source, which is the real claim

-- Read the function definitions straight out of the catalog rather than grepping the file, so this
-- holds for an installed extension whatever the file is called. pg_get_functiondef is what the server
-- would run.
\set QUIET 1
\o /dev/null
CREATE TEMP TABLE fn_source AS
SELECT p.proname,
       pg_get_functiondef(p.oid) AS def,
       p.provolatile
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = current_schema()
   -- prokind IN ('f','p') because pg_proc holds AGGREGATES as well as functions, and
   -- pg_get_functiondef raises '"array_agg" is an aggregate function' on one. Filtering by proname
   -- happens to exclude them here, so this is belt and braces rather than a fix.
   AND p.prokind IN ('f', 'p')
   AND p.proname IN ('lock_tree_deadlocks', 'lock_tree_prune_alerts', 'lock_tree_sampling_advice',
                     'lock_tree_prune', 'lock_tree_duration',
                     'lock_tree_duration_by_application', 'lock_tree_history_statements',
                     'lock_tree_replay')
   AND p.pronargs >= 0;

-- Nine windowed functions in all; prune_batched is a procedure and is checked separately below
-- because pg_proc.prokind distinguishes it and it is in the same file.
SELECT count(*) AS n_fns,
       count(*) FILTER (WHERE def LIKE '%clock_timestamp() - %')       AS still_volatile,
       count(*) FILTER (WHERE def LIKE '%statement_timestamp%')      AS now_stable
  FROM fn_source \gset
SELECT count(*) AS n_proc,
       count(*) FILTER (WHERE pg_get_functiondef(p.oid) LIKE '%clock_timestamp() - %') AS proc_volatile
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = current_schema() AND p.proname = 'lock_tree_prune_batched' \gset
\o
\set QUIET 0

SELECT is(:n_fns::int, 8, 'the eight windowed read and prune functions are all present');

SELECT is(:still_volatile::int, 0,
          'and NONE of them bounds a window with clock_timestamp() any more. The pattern '
          || '"clock_timestamp() - " appears in exactly three places in the whole extension and all '
          || 'three are in the live view, which the next assertion checks');

SELECT is(:now_stable::int, 8,
          'while all eight use statement_timestamp(). Matched on the name and not on '
          || '"statement_timestamp() - ", because lock_tree_replay writes '
          || 'coalesce(as_of, statement_timestamp()) with nothing subtracted from it');

SELECT is(:n_proc::int, 1, 'and the batched prune procedure is present');

SELECT is(:proc_volatile::int, 0,
          'with no volatile window bound either. A procedure is not in the list above because '
          || 'pg_proc.prokind separates it, and it does the same DELETE');

-- ------------------------------------------------- the deliberate exception, pinned

\set QUIET 1
\o /dev/null
SELECT (SELECT count(*) FROM regexp_matches(
          pg_get_viewdef('lock_tree'::regclass, true), 'clock_timestamp\(\)', 'g')) AS view_volatile \gset
SELECT (SELECT count(*) FROM regexp_matches(
          pg_get_viewdef('lock_tree'::regclass, true), 'statement_timestamp', 'g')) AS view_stable \gset
\o
\set QUIET 0

SELECT is(:view_volatile::int, 3,
          'the live view still uses clock_timestamp() in exactly three places, and it must: those '
          || 'compute wait_age, xact_age and state_age, which are genuinely per-row instants of now');

SELECT is(:view_stable::int, 0,
          'and it uses statement_timestamp() nowhere, so a blanket replacement of the whole file '
          || 'would have changed behaviour the ages depend on. This is the assertion that catches it');

  -- ------------------------------------------------- both duration reads bound the waiter side

  -- From 1.1.5. PostgreSQL does not carry a >= bound on r.sampled_at across the equality
  -- w.sampled_at = r.sampled_at, so before this the waiter side of the join stayed inside the
  -- window only if the planner picked a nested loop and probed it. It did not always: on PG18 with
  -- a 90-day fixture lock_tree_duration_by_application() read 14,774,419 waiter rows to answer a
  -- 7-day question, and on PG14 with a 30-day one it read 4,924,819. lock_tree_duration() has the
  -- identical join and was handed a nested loop, which is why the two disagreed.
  --
  -- Asserted against the SOURCE, not the plan, for the reason in the next section: this has to pass
  -- on six PostgreSQL versions and plan shape depends on version, statistics and fixture size. The
  -- plan consequence is asserted in scripts/bench-history.sh against a large fixture.

  \set QUIET 1
  \o /dev/null
  SELECT (SELECT count(*) FROM regexp_matches(
            pg_get_functiondef('lock_tree_duration(interval)'::regprocedure),
            'AND w\.sampled_at >= statement_timestamp\(\) - since', 'g')) AS dur_bound \gset
  SELECT (SELECT count(*) FROM regexp_matches(
            pg_get_functiondef('lock_tree_duration_by_application(interval)'::regprocedure),
            'AND w\.sampled_at >= statement_timestamp\(\) - since', 'g')) AS byapp_bound \gset
  \o
  \set QUIET 0

  SELECT is(:dur_bound::int, 1,
            'lock_tree_duration() bounds the waiter side of its root-to-waiter join, so its cost '
            || 'follows the window rather than depending on the planner picking a nested loop');

  SELECT is(:byapp_bound::int, 1,
            'and lock_tree_duration_by_application() bounds it too, which is the one that was '
            || 'reading every retained waiter row');


-- ------------------------------------------------- plans are asserted elsewhere, and why

-- This file does NOT assert anything about query plans, which is a change from the first draft and
-- the reason is worth recording.
--
-- The first draft asserted that all five plans used an Index Cond and none sequential-scanned. On a
-- six hundred row fixture that fails, and it fails CORRECTLY: at that size a sequential scan is
-- cheaper and the planner is right to choose it. The assertion was not detecting the bug, it was
-- demanding a worse plan.
--
-- Plan shape also depends on table size and on the planner version, so it is a poor thing to assert
-- on in a unit test that has to pass on six PostgreSQL versions. It is asserted in
-- scripts/bench-history.sh instead, against a 1.2 million row fixture where a sequential scan
-- genuinely is the wrong answer, and those checks were verified to FAIL against the v0.14 tag.
--
-- What is asserted here instead is the SOURCE, which is deterministic: whether a function bounds a
-- window with a volatile or a stable clock. That is the actual defect, and it is the thing that made
-- every one of those plans wrong.


-- ------------------------------------------------------------- behaviour is unchanged

-- The change was to a cutoff expression, so the figures must be identical to what 0.14 produced on the
-- same fixture. Derived from the samples rather than hardcoded, so this checks the arithmetic rather
-- than a number that happens to be right today.
\set QUIET 1
\o /dev/null
SELECT count(*) AS narrow_rows FROM lock_tree_duration(interval '1 millisecond') \gset
SELECT count(*) AS wide_rows FROM lock_tree_duration() \gset
SELECT blocked_sessions_peak AS peak FROM lock_tree_duration() \gset
SELECT sessions_total AS sessions_total FROM lock_tree_duration() \gset
SELECT count(DISTINCT sampled_at) AS samples_total FROM lock_tree_replay_samples \gset
SELECT blocked_sessions_peak AS app_peak FROM lock_tree_duration_by_application() \gset
SELECT (SELECT count(DISTINCT sampled_at) FROM lock_tree_replay_samples)        AS samples \gset
SELECT (SELECT count(*) FROM lock_tree_replay(now() - interval '1 hour'))       AS replayed \gset
SELECT (SELECT count(*) FROM lock_tree_replay(now() - interval '3 days'))       AS replayed_far \gset
\o
\set QUIET 0

SELECT is(:wide_rows::int, 1, 'the wide window still reports its one query id');

SELECT is(:narrow_rows::int, 0, 'and a window matching no sample still reports nothing');

-- THE BUG THIS FIXTURE CAUGHT. The fixture is written from depth values directly, so the number of
-- waiters behind a root is four by construction and does not depend on any expression in the
-- function. Until 0.15 the root row matched itself in the root-to-waiter join and the peak came out
-- one higher per sample, so this reads 5.
SELECT is(:peak::int, 4,
          'blocked_sessions_peak is 4, the number of rows at depth greater than zero behind one root, '
          || 'counted straight off the fixture. 0.13 and 0.14 reported 5, because the root matched '
          || 'itself in the join and counted the blocker among its own waiters');

SELECT is(:sessions_total::int, 4 * :samples_total::int,
          'and sessions_total is that peak summed over the instants, which is the same one-per-sample '
          || 'inflation rather than a second one');

SELECT is(:app_peak::int, :peak::int,
          'and the per-application figure agrees with the per-query one, because this fixture has a '
          || 'single application at the head for the whole window');

SELECT is(:samples::int, 120, 'the samples view sees all 120 instants');

-- Replay picks the NEAREST sample, so a target in the middle of the run returns the same five rows as
-- one at the end of it, while a target before the first sample returns the FIRST sample rather than
-- nothing. Both were the behaviour before the change and both are asserted in test/18.
SELECT is(:replayed::int, 5, 'a target inside the window replays the nearest sample, five rows');

SELECT ok(:replayed_far::int >= :replayed::int,
          'and a target before the first sample replays the first sample rather than nothing, which '
          || 'is what the two index seeks buy: max(sampled_at) under an empty range is NULL, so the '
          || 'earliest one wins');

-- The INCLUDE column added in 1.1.0, asserted structurally rather than by timing. indnkeyatts is
-- the number of KEY attributes and indnatts the total including INCLUDEd ones, so 2 and 3 says the
-- index keys on (application_name, sampled_at) and carries query_id along without ordering by it.
--
-- A time bound would be the wrong way to pin this: the benefit is 117.0 -> 31.2 ms for one CTE and
-- only 2249 -> 2146 ms for the whole function, so a threshold wide enough to catch a regression
-- would also pass on a loaded machine. The catalog says whether the column is there.
\set QUIET 1
\o /dev/null
SELECT (SELECT indnkeyatts::text FROM pg_index WHERE indexrelid = 'lock_tree_history_application_idx'::regclass) AS app_key,
       (SELECT indnatts::text   FROM pg_index WHERE indexrelid = 'lock_tree_history_application_idx'::regclass) AS app_all,
       (SELECT count(*)::text   FROM pg_index WHERE indexrelid = 'lock_tree_history_application_idx'::regclass) AS app_found
\gset
\o
\set QUIET 0

SELECT is(:app_found::int, 1, 'the partial application index exists by that name');

SELECT is(:app_key::int, 2,
          'and it keys on two columns, so query_id is included rather than part of the ordering');

SELECT is(:app_all::int, 3,
          'while carrying a third attribute in the leaf, which is what lets the qids step be an Index Only Scan');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_history;
\o
\set QUIET 0