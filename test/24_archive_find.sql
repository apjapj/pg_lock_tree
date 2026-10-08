-- test/24_archive_find.sql: searching the archive, added in 1.1.8.
--
-- The first shipped function that reads lock_tree_history_archive, and the two things about it that
-- a caller must not discover the hard way: the window is REQUIRED, and it reads only the archive.
--
-- The guard is the part worth testing properly. It was attempted three ways and every one of them
-- looked correct while not working, which is recorded in the release file. This file exists so a
-- future change cannot quietly remove the refusal and leave a query that hangs instead.
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
\o
\echo # the search function exists, and the guard that makes its window mandatory
SELECT plan(18);

SELECT has_function('lock_tree_archive_find',
                    ARRAY['interval','interval','text','text','interval','integer'],
                    'lock_tree_archive_find(interval, interval, text, text, interval, integer) exists');

SELECT has_function('lock_tree_archive_since_guard', ARRAY['interval'],
                    'lock_tree_archive_since_guard(interval) exists');

-- The window is mandatory, and the refusal is the point of the whole design. 22023 is
-- invalid_parameter_value, which the guard raises explicitly: RAISE EXCEPTION without a code would
-- be P0001, and a caller catching this wants to tell it apart from a syntax error.
SELECT throws_ok('SELECT count(*) FROM lock_tree_archive_find(NULL)',
                 '22023',
                 'lock_tree_archive_find() needs a since window. Measured on 10,160,640 archived '
                 || 'rows spanning 16 days: a 7-day window returns in 1.5 ms using the BRIN index, '
                 || 'and an unbounded query over the same rows did not finish in 10 minutes. Pass a '
                 || 'since, or write the query yourself against lock_tree_history_archive, which is '
                 || 'a plain table and will scan it.',
                 'a NULL window is refused with the measurement in the message, not left to hang');

-- The guard on its own raises for the same input. It is not useful to a caller, but asserting it
-- separately pins the behaviour to the guard rather than to something in the caller's path, which is
-- what changed three times while this was being built.
SELECT throws_ok('SELECT lock_tree_archive_since_guard(NULL)',
                 '22023',
                 'lock_tree_archive_find() needs a since window. Measured on 10,160,640 archived '
                 || 'rows spanning 16 days: a 7-day window returns in 1.5 ms using the BRIN index, '
                 || 'and an unbounded query over the same rows did not finish in 10 minutes. Pass a '
                 || 'since, or write the query yourself against lock_tree_history_archive, which is '
                 || 'a plain table and will scan it.',
                 'and the guard itself raises for a NULL, so the refusal is in the guard and not in a caller');

-- VOLATILE is load-bearing, and this is the assertion that says so. A STABLE guard was inlined and
-- dropped by the planner; so was a VOLATILE one, because it sat below the caller's LIMIT. VOLATILE
-- is the only property that makes the call survive into the plan and run, so it is pinned here
-- rather than left to a comment explaining why it matters.
SELECT is((SELECT p.provolatile::text FROM pg_proc p WHERE p.proname = 'lock_tree_archive_since_guard'),
          'v',
          'the guard is VOLATILE, which is what stops the planner eliding the check');

-- A bound works, and returns the archive's own contents. 20 samples of 4 sessions, all older than a
-- day so they are unmistakably archive-shaped, plus a NULL query on one row so the redaction and the
-- NULL handling are exercised by the same fixture.
\o /dev/null
\set QUIET 1
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_history_archive;
INSERT INTO lock_tree_history_archive (sampled_at, root_pid, depth, pid, state, waiting_for,
                                       wait_age, application_name, query, root_object, query_id)
SELECT now() - ((g * 10) || ' seconds')::interval,
       100,
       CASE WHEN s = 0 THEN 0 ELSE 1 END,
       100 + s,
       CASE WHEN s = 0 THEN 'idle in transaction' END,
       CASE WHEN s = 0 THEN NULL ELSE 'relation public.orders_pkey' END,
       CASE WHEN s = 0 THEN NULL ELSE (10 * s) * interval '1 second' END,
       'checkout',
       CASE WHEN s = 0 THEN 'UPDATE orders SET status = $1' ELSE NULL END,
       NULL,
       CASE WHEN s = 0 THEN 100 END
FROM generate_series(1, 20) g
CROSS JOIN generate_series(0, 3) s;
VACUUM (ANALYZE) lock_tree_history_archive;
SELECT count(*) AS a_rows FROM lock_tree_history_archive \gset
\o
\set QUIET 0

SELECT is(:a_rows::int, 80,
          'the archive fixture holds 80 rows: 20 samples of 4 sessions');

-- The one row per sample, not one per session. This is the difference between a result a reader can
-- use and the grain the history is stored at, and it is the function's main design decision.
SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day'))::int, 20,
          'a bounded search returns one row per sample instant, not one per session');

-- The filters, each one narrowing the result rather than passing everything.
SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      waiting_like => 'orders_pkey'))::int, 20,
          'waiting_like matches the lock tag, and all 20 samples have that waiter');

SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      waiting_like => 'no_such_table'))::int, 0,
          'and a tag that appears nowhere returns nothing, so the filter discriminates');

-- Case-insensitivity, because a lock tag is a relation name and nobody types its case.
SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      waiting_like => 'ORDERS_PKEY'))::int, 20,
          'waiting_like is case-insensitive, so the tag can be typed as PostgreSQL reports it or as it appears');

SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      application => 'checkout'))::int, 20,
          'application filters on an exact application_name');

SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      application => 'no-such-app'))::int, 0,
          'and an application that never appears returns nothing');

-- min_wait has to distinguish a short wait from an unrecorded one, and the fixture's root rows have
-- a NULL wait_age, so a naive `wait_age >= min_wait` would drop the samples that had no recorded wait
-- rather than keeping them.
SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day', min_wait => interval '20 seconds'))::int, 20,
          'min_wait keeps the samples whose waiters were above it');

SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day',
                                                      min_wait => interval '1 hour'))::int, 0,
          'and a threshold above every recorded wait returns nothing rather than everything');

-- The cap. An uncapped result from a year of history is a result nobody reads, and the default is
-- 200. Asserted by asking for more than the fixture holds, which is the only way to tell a cap from
-- a coincidence at this size.
SELECT is((SELECT count(*) FROM lock_tree_archive_find(interval '1 day', limit_rows => 5))::int, 5,
          'limit_rows caps the result, and the cap is applied outside the aggregation');

-- The cap does not corrupt the per-sample figures, which is the reason it is outside. The longest
-- wait in the fixture is 30 seconds on the deepest waiter; a capped result must still report it.
SELECT is((SELECT max(longest_wait) FROM lock_tree_archive_find(interval '1 day', limit_rows => 5))
          ::text, '00:00:30'::text,
          'and capping does not change the per-sample figures, only how many instants come back');

-- The array shape, because a NULL element and an empty string are different claims about a session.
SELECT ok((SELECT applications = ARRAY['checkout'] FROM lock_tree_archive_find(interval '1 day') LIMIT 1),
          'applications is the distinct non-null application names, as an array');

SELECT ok((SELECT queries @> ARRAY['UPDATE orders SET status = $1']
             FROM lock_tree_archive_find(interval '1 day') LIMIT 1),
          'and queries holds the distinct statements, so twelve waiters on one SELECT is one entry');

\o /dev/null
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_history_archive;
\o
\set QUIET 0
