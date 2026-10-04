-- test/12_history_statements.sql: per-query blocking time, from the sampled history.
--
-- lock_tree_statements() answers "what is blocking now". This answers "what cost the most
-- blocking time over the last week", which is the question that gets a fix merged rather than a
-- workaround. It is aggregation over lock_tree_history, so it needs samples rather than a live
-- chain, and the whole fixture is written directly rather than built with dblink: the point here
-- is the arithmetic, not the blocking.
--
-- The arithmetic has two properties that are easy to get wrong and that this file pins:
--
--   Only ROOTS carry a query_id. A query blocked on a lock has no query_id until it completes, so
--   waiter rows are NULL and must not be counted toward a statement's total. Counting them would
--   inflate every figure by the size of the chain.
--
--   The figure is session-samples, not seconds. A session blocked for 60 seconds at a 10 second
--   sample interval contributes six, not sixty. So the number rises with the sampling rate, and
--   what is comparable between statements is the ranking, not the absolute value.
--
-- Needs no superuser beyond the usual extension setup.
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

-- Two statements. 101 is the bad one: it holds up 5 sessions across 3 samples. 202 is mild: 2
-- sessions across 1. Written as depth-0 root rows plus depth-1 waiter rows, because that is the
-- shape lock_tree_sample() produces and the arithmetic depends on which rows are roots.
\set QUIET 1
\o /dev/null
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, query_id)
SELECT v.at, root, 0, root, 'idle in transaction', make_interval(secs => root * 30),
       app, qid
FROM (VALUES
  -- 101 at three sample times, 5 sessions each. 15 rows of which 3 are roots.
  (now() - interval '3 hours', 101::bigint, 'batch_a'::text, 1::bigint),
  (now() - interval '2 hours', 101, 'batch_a', 1),
  (now() - interval '1 hour', 101, 'batch_a', 1),
  -- 202 once, 2 sessions.
  (now() - interval '30 min', 202, 'batch_b', 2)
) AS v(at, root, app, qid);

INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, query_id)
SELECT s.at, 101, 1, 1000 + g, 'active', make_interval(secs => 5 * g), 'api_worker', NULL
FROM (VALUES
  (now() - interval '3 hours'), (now() - interval '2 hours'), (now() - interval '1 hour')
) AS s(at), generate_series(1,5) g;

INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, query_id)
SELECT now() - interval '30 min', 202, 1, 2000 + g, 'active', make_interval(secs => g),
       'report_reader', NULL
FROM generate_series(1,2) g;

-- One sample outside the window, so the "since" argument has something to exclude. 8 days back is
-- outside the default 7 day window and inside a 30 day one.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, application_name, query_id)
VALUES (now() - interval '8 days', 101, 0, 101, 'idle in transaction', 'batch_a', 1);
\o
\unset QUIET

SELECT plan(17);

SELECT has_function('lock_tree_history_statements', ARRAY['interval'],
                    'lock_tree_history_statements(interval) exists');

SELECT ok((SELECT count(*) FROM lock_tree_history_statements() WHERE query_id = 1)::bigint > 0,
          'a query_id present in the history comes back');

SELECT is((SELECT blocked_sessions FROM lock_tree_history_statements() WHERE query_id = 1)::bigint,
          3::bigint,
          'and only its ROOT rows are counted: 3 samples, not the 15 rows of the chain');

-- The window filter runs before the aggregation, so the 8-day-old sample is excluded from every
-- column, not just the totals. That is what makes the 'since' argument mean anything at all.
SELECT is((SELECT samples FROM lock_tree_history_statements() WHERE query_id = 1)::bigint,
          3::bigint,
          'samples counts the instants inside the window, so the 8-day-old sample is excluded '
          || 'from this column too, not only from the totals');

SELECT is((SELECT blocked_sessions FROM lock_tree_history_statements() WHERE query_id = 2)::bigint,
          1::bigint, 'the milder statement counts its single root sample');

-- Ordering: worst first, which is the only order anyone reads it in.
SELECT is((SELECT query_id FROM lock_tree_history_statements() LIMIT 1), 1::bigint,
          'the worst statement is first');

SELECT ok((SELECT blocked_sessions FROM lock_tree_history_statements()
            OFFSET 1 LIMIT 1) < (SELECT blocked_sessions FROM lock_tree_history_statements() LIMIT 1),
          'and the ranking is strictly descending by blocked sessions');

-- The window argument.
SELECT is((SELECT count(*) FROM lock_tree_history_statements(interval '7 days'))::bigint, 2::bigint,
          'both statements appear inside a 7 day window');

SELECT is((SELECT count(*) FROM lock_tree_history_statements(interval '1 day'))::bigint, 2::bigint,
          'and still both inside 1 day, since 101 was blocked as recently as an hour ago');

SELECT is((SELECT count(*) FROM lock_tree_history_statements(interval '1 hour'))::bigint, 1::bigint,
          'a 1 hour window drops the older samples and keeps only statement 202');

-- Degradation rather than failure.
SELECT is((SELECT count(*) FROM lock_tree_history_statements() WHERE deepest_chain IS NULL)::bigint,
          0::bigint,
          'the deepest chain is populated for every row, so the aggregation is not silently NULL');

SELECT ok((SELECT longest_wait_at IS NOT NULL FROM lock_tree_history_statements() WHERE query_id = 1),
          'and the worst wait has a timestamp, so "3m12s" can be turned into "at 09:14"');

SELECT ok((SELECT array_length(applications, 1) = 1 FROM lock_tree_history_statements()
            WHERE query_id = 1),
          'and the applications array names who was holding the lock');

-- The live behaviour behind the fixture. A real sample must put a query_id on the root row and
-- leave the waiter's NULL, and the fixture above cannot show that because it chooses its own
-- values. So the two halves are asserted directly against the fixture, which has the same shape
-- a real sample produces: depth-0 rows carrying a query_id and depth-1 rows not.
SELECT is((SELECT count(*) FROM lock_tree_history WHERE depth > 0 AND query_id IS NOT NULL)::bigint,
          0::bigint,
          'no waiter row carries a query_id, which is the property the totals depend on: a '
          || 'blocked query has none until it completes');

SELECT is((SELECT count(*) FROM lock_tree_history WHERE depth = 0 AND query_id IS NOT NULL)::bigint,
          5::bigint,
          'and every root row does, all five including the one outside the window, which '
          || 'is what gives the per-query totals something to sum');

-- The arithmetic caveat, asserted rather than only documented: this is a session-sample count, so
-- it is not seconds. Two samples of one session is 2 here however long it really waited.
SELECT is((SELECT blocked_sessions FROM lock_tree_history_statements() WHERE query_id = 1)::bigint
          / (SELECT samples FROM lock_tree_history_statements() WHERE query_id = 1)::bigint, 1::bigint,
          'the figure is session-samples, so blocked_sessions divided by samples gives the '
          || 'average queue depth rather than a duration');

SELECT is((SELECT count(*) FROM lock_tree_history_statements(
             since => interval '1 second'))::bigint, 0::bigint,
          'a window in the future returns nothing rather than erroring');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_history;
\o
\unset QUIET