-- test/13_prepared_roots.sql: two prepared transactions are two roots.
--
-- Until 0.8 they were one. pg_blocking_pids() reports the blocker as 0 for every prepared
-- transaction, because a prepared transaction has no backend, so every prepared root had pid 0 and
-- everything that grouped on the pid merged them. The symptom was a single row claiming a blast
-- radius that no single transaction held:
--
--     root_pid | root_object | blocked_sessions
--            0 | (null)      |                 4     <- two blockers, 2 each
--
-- So the number an operator acts on was wrong, in the one case this extension exists to be better
-- than the published recursive CTE at, since that CTE reports a prepared transaction as nothing at
-- all. Getting that case right matters more than being right about it, which is why this file is
-- separate from test/04_prepared.sql rather than folded into it.
--
-- Needs superuser (dblink), max_prepared_transactions > 0, and the dblink contrib module.
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

-- Unique table names: test/04_prepared.sql has its own, and two files creating the same relation
-- in one run is how a suite starts failing for reasons that have nothing to do with what it tests.
DROP TABLE IF EXISTS lock_tree_pr1;
DROP TABLE IF EXISTS lock_tree_pr2;
DROP TABLE IF EXISTS lock_tree_pr_pids;
CREATE TABLE lock_tree_pr1 (id int);
CREATE TABLE lock_tree_pr2 (id int);
CREATE TABLE lock_tree_pr_pids (name text primary key, pid int);

TRUNCATE lock_tree_history;
TRUNCATE lock_tree_alert;

CREATE TEMP TABLE pr_names AS
SELECT 'h1' AS n UNION ALL SELECT 'h2'
UNION ALL SELECT 'w' || i FROM generate_series(1,2) i;

SELECT dblink_connect(s.n, format('dbname=%s user=%s', current_database(), current_user))
FROM pr_names s;

INSERT INTO lock_tree_pr_pids
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int))
FROM pr_names s;

-- The lock has to be taken BEFORE preparing, or the prepared transaction holds nothing and blocks
-- nobody. That was the first attempt at this fixture and it produced a silently empty tree.
SELECT dblink_exec('h1', 'BEGIN');
SELECT dblink_exec('h1', 'LOCK TABLE lock_tree_pr1 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('h1', 'PREPARE TRANSACTION ''lock_tree_pr_alpha''');
SELECT dblink_exec('h2', 'BEGIN');
SELECT dblink_exec('h2', 'LOCK TABLE lock_tree_pr2 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('h2', 'PREPARE TRANSACTION ''lock_tree_pr_beta''');

-- One statement per connection. dblink allows one in-flight command per connection, so a separate
-- send_query for the SET fails with "another command is already in progress".
SELECT dblink_send_query('w1', 'SET application_name = ''api_a''; SELECT count(*) FROM lock_tree_pr1');
SELECT dblink_send_query('w2', 'SET application_name = ''api_b''; SELECT count(*) FROM lock_tree_pr2');

DO $wait$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a
               JOIN lock_tree_pr_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS onset  \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS repeat1 \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS repeat2 \gset
SELECT lock_tree_sample() AS sampled \gset
\o
\set QUIET 0

SELECT plan(22);

-- ------------------------------------------------------------------ the tree

SELECT has_column('lock_tree', 'root_object',
                  'lock_tree has a root_object column, which is what makes this file possible');

SELECT is((SELECT count(*) FROM lock_tree WHERE depth = 0), 2::bigint,
          'two prepared transactions give two depth-0 rows, where 0.7 gave one');

SELECT is((SELECT count(DISTINCT root_object) FROM lock_tree WHERE depth = 0), 2::bigint,
          'and their root_objects differ, which is the whole point');

SELECT is((SELECT count(*) FROM lock_tree WHERE depth = 0 AND root_object IS NULL), 0::bigint,
          'no prepared root has a NULL object: there is always a lock it is holding');

SELECT is((SELECT count(*) FROM lock_tree WHERE depth > 0 AND root_object IS NULL), 0::bigint,
          'and no waiter either, since a waiter inherits its chain root identity');

-- Each waiter sits under the root for the object it is actually waiting on. Getting this wrong is
-- what produced one chain of four waiters belonging to two blockers.
SELECT is((SELECT count(*) FROM lock_tree t
           WHERE t.depth > 0
             AND t.root_object LIKE '%' || split_part(t.waiting_for, ' on ', 2) || '%'), 2::bigint,
          'each waiter hangs under the root holding the object it wants, not under both');

SELECT is((SELECT count(*) FROM lock_tree WHERE depth > 0), 2::bigint,
          'two waiters, no more: nothing was duplicated or lost by the split');

-- ------------------------------------------------------------------ the aggregates

SELECT is((SELECT roots FROM lock_tree_summary()), 2::bigint,
          'lock_tree_summary() counts two roots, where 0.7 said one');

SELECT is((SELECT blocked_sessions FROM lock_tree_summary()), 2::bigint,
          'and the total blocked sessions is unchanged at 2: only the root count was wrong');

SELECT is((SELECT count(*) FROM lock_tree_wide()), 2::bigint,
          'lock_tree_wide() returns one row per prepared root');

SELECT is((SELECT count(DISTINCT blocked_sessions) FROM lock_tree_wide()), 1::bigint,
          'each blocking exactly one session');

SELECT is((SELECT max(blocked_sessions) FROM lock_tree_wide()), 1::bigint,
          'so the worst of them blocks 1, not the merged 2 that 0.7 reported');

SELECT is((SELECT count(*) FROM lock_tree_roots()), 2::bigint,
          'lock_tree_roots() also returns two rows');

SELECT ok((SELECT bool_and(suggested_action LIKE '%' || root_object || '%')
          FROM lock_tree_roots()),
          'and each suggested_action names the object it is holding');

SELECT is((SELECT count(*) FROM lock_tree_statements()), 2::bigint,
          'lock_tree_statements() agrees, so a caller grouping incidents by it sees two');

-- The row-for-row pg_stat_statements join this replaced produced two rows for one root, because
-- queryid is not unique there. One row per wide row is the invariant, and it is what the previous
-- version broke.
SELECT is((SELECT count(*) FROM lock_tree_statements()),
          (SELECT count(*) FROM lock_tree_wide()),
          'lock_tree_statements() returns exactly as many rows as lock_tree_wide(), which is the '
          || 'invariant a duplicate pg_stat_statements bucket used to break');

-- ------------------------------------------------------------------ history and alerting

SELECT is((SELECT count(*) FROM lock_tree_history WHERE depth = 0 AND root_object IS NOT NULL), 2::bigint,
          'lock_tree_sample() records root_object, so history keeps the two roots apart');

SELECT is((SELECT array_length(root_objects, 1) FROM lock_tree_incidents()), 2,
          'and lock_tree_incidents() names both objects for the incident');

SELECT is(:onset::int, 2,
          'onset fires once per prepared root, so 2 here');

SELECT is(:repeat1::int, 0,
          'and a second identical call is 0: the two roots are tracked separately, so neither '
          || 'suppresses the other');

SELECT is(:repeat2::int, 0, 'and stays at 0 on a third call');

SELECT is(:sampled::bigint, 4::bigint,
          'the sample captured all four rows: two roots and two waiters');

SELECT * FROM finish();

-- Cleanup. ROLLBACK PREPARED cannot run inside a transaction block or through plpgsql EXECUTE, so
-- these are plain statements rather than a DO block, which is also why a failure earlier in this
-- file leaks them. The next run's DROP TABLE would block forever on such a leak, which is a loud
-- failure rather than a wrong result, so that is the trade.
\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(pid) FROM lock_tree_pr_pids;
DO $b$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM pr_names LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$b$;
TRUNCATE lock_tree_alert;
TRUNCATE lock_tree_history;
\o
\set QUIET 0

ROLLBACK PREPARED 'lock_tree_pr_alpha';
ROLLBACK PREPARED 'lock_tree_pr_beta';

\set QUIET 1
\o /dev/null
DROP TABLE lock_tree_pr_pids;
DROP TABLE lock_tree_pr1;
DROP TABLE lock_tree_pr2;
\o
\set QUIET 0