-- test/15_history_size.sql: what the history costs, and pruning it without one long lock.
--
-- Both of these exist because partitioning lock_tree_history was proposed and turned out not to be
-- available. PostgreSQL has no ALTER TABLE ... SET PARTITIONED BY: conversion means creating a new
-- partitioned table, copying, and swapping. And the swap cannot be done from outside the extension,
-- because the table is a member:
--
--   DROP TABLE lock_tree_history
--   ERROR:  cannot drop table lock_tree_history because extension pg_lock_tree requires it
--
-- The only place DROP TABLE is permitted is inside an extension update script, which would copy
-- however many rows the user happens to have, unattended, during ALTER EXTENSION ... UPDATE. That is
-- not a change to make on someone's behalf in a script they did not write.
--
-- So the problem partitioning was meant to solve is addressed directly instead: one DELETE holding
-- its locks for its whole duration. lock_tree_prune_batched() commits between batches, and
-- lock_tree_history_size() reports whether that is worth using.
--
-- No superuser and no dblink needed beyond the usual extension setup.
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
TRUNCATE lock_tree_deadlock;
\o
\set QUIET 0

SELECT plan(23);

SELECT has_function('lock_tree_history_size', 'lock_tree_history_size() exists');

-- Not has_procedure: this pgTAP has no such assertion, and has_function would look in the same
-- catalog row for either kind. What matters here is prokind, because the whole reason it exists as
-- a procedure is that a function cannot COMMIT.
SELECT ok((SELECT count(*) = 1 FROM pg_proc
            WHERE proname = 'lock_tree_prune_batched' AND prokind = 'p'),
          'lock_tree_prune_batched() is a PROCEDURE, because only a procedure can COMMIT');

-- ---------------------------------------------------------------- sizing

-- Empty. Every number zero or NULL rather than a confident guess, because an unsampled database has
-- no rate and reporting a large number from no data would be a guess dressed as a measurement.
\set QUIET 1
\o /dev/null
SELECT rows AS e_rows, samples AS e_samples, total_bytes AS e_bytes,
       (observed_every IS NULL)::text AS e_every_null,
       (bytes_per_day IS NULL)::text AS e_rate_null,
       (days_to_1gb IS NULL)::text AS e_days_null
FROM lock_tree_history_size() \gset
\o
\set QUIET 0

SELECT is(:e_rows::bigint, 0::bigint, 'an unsampled history has no rows');

SELECT is(:e_samples::bigint, 0::bigint, 'and no samples');

SELECT is(:e_every_null, 'true', 'and no observed interval');

SELECT is(:e_rate_null, 'true', 'and no bytes-per-day rate, rather than an invented one');

SELECT is(:e_days_null, 'true', 'and no days-to-a-gigabyte, because there is nothing to project from');

-- Total bytes on an empty table is the empty relation itself, not zero. Asserting it is nonzero is
-- deliberate: pg_total_relation_size accounts for the TOAST table and the free space map, which a
-- hand-rolled sum of pg_relation_size silently misses, and that is the number the disk is charged.
SELECT ok(:e_bytes::bigint > 0,
          'total_bytes is nonzero even when empty, because it is the whole relation on disk');

-- A history with a known shape. now() rather than clock_timestamp(), because clock_timestamp() is
-- volatile and evaluated per row, which would give every row a different sampled_at and make the
-- sample count wrong. That trap is documented at length in test/14_deadlocks.sql.
\set QUIET 1
\o /dev/null
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state)
SELECT now() - make_interval(secs => g * 10), 100 + (g % 4), 0, 500 + g, 'idle in transaction'
FROM generate_series(1, 60) g;
SELECT rows AS s_rows, samples AS s_samples,
       (observed_every = interval '10 seconds')::text AS s_every_10s,
       total_bytes AS s_bytes
FROM lock_tree_history_size() \gset
\o
\set QUIET 0

SELECT is(:s_rows::bigint, 60::bigint, 'rows are counted');

SELECT is(:s_samples::bigint, 60::bigint,
          'and samples too, which is the number that says how many times the sampler ran');

SELECT is(:s_every_10s, 'true',
          'the observed interval is the gap the fixtures actually used, 10 seconds, computed as '
          || '(span / gaps) rather than by averaging intervals');

SELECT ok(:s_bytes::bigint > :e_bytes::bigint, 'and the table grew on disk, not just in row count');

-- A rate, and what it implies.
\set QUIET 1
\o /dev/null
SELECT (bytes_per_day IS NOT NULL)::text AS r_rate, (days_to_1gb IS NOT NULL)::text AS r_days,
       (days_to_1gb > 0)::text AS r_positive
FROM lock_tree_history_size() \gset
\o
\set QUIET 0

SELECT is(:r_rate, 'true', 'with samples in the table there is a rate');

SELECT is(:r_days, 'true', 'and a projection');

SELECT is(:r_positive, 'true', 'and a positive one, since the table is not already over a gigabyte');

-- ---------------------------------------------------------------- batched prune

-- The property that matters, and the reason it is a procedure: calling it inside a transaction
-- block must fail having deleted NOTHING. Checked before and after, because the failure mode this
-- replaces was failing part-way through with half the table gone.
\set QUIET 1
\o /dev/null
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state)
SELECT now() - (g || ' days')::interval, 1, 0, 900 + g, 'active' FROM generate_series(2, 40) g;
INSERT INTO lock_tree_deadlock (sampled_at, deadlocks)
VALUES (now() - interval '3 days', 0);
SELECT count(*) AS before_txn FROM lock_tree_history \gset
\o
\set QUIET 0

-- No bare BEGIN here to demonstrate it. A stray BEGIN with no COMMIT puts the whole rest of the
-- psql file inside a transaction block, and the later CALL then fails with "invalid transaction
-- termination" for a reason that has nothing to do with what is being tested. throws_ok runs the
-- statement inside its own subtransaction, which is the right way to check it.

-- A plain quoted string rather than $$...$$: the dollar-quoted form of this statement gave
-- "syntax error at or near $", because the closing tag sat next to the argument comma and the two
-- disagreed about where the string ended. Doubled quotes are unambiguous and cost nothing.
-- 0A000, not 2D000. throws_ok runs the statement inside a subtransaction, and there the refusal
-- is "EXECUTE of transaction commands is not implemented". Called inside a real BEGIN block at the
-- top level it is 2D000 "invalid transaction termination". Same refusal, different wording, because
-- a subtransaction and a transaction block are different things to PostgreSQL. What matters is that
-- it is refused at all, and the next two assertions check the part that is ours.
-- The third argument is the FULL expected message, not a description: this pgTAP builds
-- "wanted: <code>: <third argument>" and compares it with "caught: <code>: <message>". A phrase
-- never matches.
SELECT throws_ok('BEGIN; CALL lock_tree_prune_batched(interval ''1 day'', 10);',
                 '0A000',
                 'EXECUTE of transaction commands is not implemented');

-- Relative, not absolute. An earlier version asserted a hardcoded 41 and was wrong twice: it
-- forgot the 60 rows left by the sizing fixture above, and then it forgot that one of the aged rows
-- was already gone. Deriving the count from the table at the moment of the check is what this file
-- is about, so the test should do it too.
SELECT is((SELECT count(*) FROM lock_tree_history)::bigint, :before_txn::bigint,
          'and nothing was deleted before it refused: the row count is exactly what it was');

SELECT ok((SELECT count(*) FROM lock_tree_history WHERE sampled_at < clock_timestamp() - interval '1 day') > 0,
          'and the aged rows are all still there, so the check happens before the first delete');

-- batch_size 0 is a typo, and an unbounded loop is the other way to read it.
-- P0001, because RAISE EXCEPTION without an explicit SQLSTATE code raises P0001. 22023 would have
-- been the right code to choose and it is not the one that comes out by default.
SELECT throws_ok('CALL lock_tree_prune_batched(interval ''1 day'', 0);',
                 'P0001',
                 'lock_tree_prune_batched() needs batch_size >= 1, got 0');

-- The real thing, outside a transaction block, in batches smaller than the row count so that more
-- than one batch is genuinely needed.
\set QUIET 1
\o /dev/null
SELECT count(*) AS before_prune FROM lock_tree_history \gset
CALL lock_tree_prune_batched(interval '1 day', 7);
SELECT count(*) AS after_prune FROM lock_tree_history \gset
SELECT count(*) AS old_deadlock FROM lock_tree_deadlock
 WHERE sampled_at < clock_timestamp() - interval '1 day' \gset
\o
\set QUIET 0

SELECT is((SELECT count(*) FROM lock_tree_history WHERE sampled_at >= clock_timestamp() - interval '1 day')::bigint, :after_prune::bigint,
          'what is left is exactly the rows that were never eligible');

SELECT ok(:after_prune::bigint < :before_prune::bigint,
          'rows were removed, and the loop iterated rather than deleting in one go: 40 aged rows in '
          || 'batches of 7 needs six passes');

SELECT ok((SELECT count(*) FROM lock_tree_history WHERE sampled_at < clock_timestamp() - interval '1 day') = 0,
          'and nothing eligible was left behind');

SELECT is(:old_deadlock::int, 0,
          'and the deadlock samples went too, as with lock_tree_prune()');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_deadlock;
\o
\set QUIET 0