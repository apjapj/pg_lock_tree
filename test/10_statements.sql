-- test/10_statements.sql: what pg_stat_statements already knows about the blocking query.
--
-- lock_tree_wide() says which root is worst. This says which *kind* of statement is doing the
-- blocking and what it normally costs, so two incidents with different pids and the same
-- queryid are recognisable as one problem rather than two coincidences.
--
-- pg_stat_statements is optional in both directions. It needs to be in
-- shared_preload_libraries to be readable at all, so this file has two halves: one that runs
-- either way and pins the graceful degradation, and one that only runs where it is loaded and
-- pins the join. A server without it must still be able to install the extension and call every
-- other function, which is the property most worth protecting.
--
-- One measured fact shapes the whole design, and it is recorded here because it is not obvious:
-- a query blocked on a lock has query_id NULL for as long as it is blocked, and only gains one
-- when it completes. So the waiter side of this join is empty during the one moment anybody
-- would want it. The root is the opposite and carries a query_id throughout. That is fortunate
-- rather than lucky, since the root is the session anyone acts on.
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

-- Two separate things are needed, and conflating them is why this test skipped on the first
-- run against the new images:
--   preloading, which is a server setting and comes from the image CMD, and
--   CREATE EXTENSION in THIS database, which creates the view.
-- Preloaded but not created gives "relation pg_stat_statements does not exist"; created but
-- not preloaded gives "must be loaded via shared_preload_libraries". So: create it when the
-- library is loaded, and test on to_regclass afterwards, which is exactly the state a user who
-- has followed the documentation is in.
DO $pgss$
BEGIN
  IF current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' THEN
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  END IF;
END
$pgss$;
SELECT (to_regclass('pg_stat_statements') IS NOT NULL) AS have_pgss \gset

DROP TABLE IF EXISTS lock_tree_st;
DROP TABLE IF EXISTS lock_tree_st_pids;
CREATE TABLE lock_tree_st (id int);
CREATE TABLE lock_tree_st_pids (name text primary key, pid int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['root','w1','w2']) AS n;

INSERT INTO lock_tree_st_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['root','w1','w2']) AS n;

-- The root runs a statement several times so pg_stat_statements has accumulated calls and
-- timings for it, then holds the lock from an open transaction. It is the root's *current*
-- statement that the join follows, so a query it has never run would match nothing.
\set QUIET 1
\o /dev/null
-- to_regclass inside the block, not the :have_pgss variable: psql does not interpolate
-- variables inside a dollar-quoted string, so ":have_pgss" reaches the parser as a colon
-- followed by an identifier and the whole DO block is a syntax error.
DO $warm$
DECLARE i int;
BEGIN
  IF to_regclass('pg_stat_statements') IS NOT NULL THEN
    FOR i IN 1..5 LOOP
      PERFORM dblink_exec('root', 'SET application_name = ''nightly_batch''');
      PERFORM dblink_exec('root', 'UPDATE lock_tree_st SET id = 1');
    END LOOP;
  END IF;
END
$warm$;
\o
\unset QUIET

SELECT dblink_exec('root', 'BEGIN');
SELECT dblink_exec('root', 'SET application_name = ''nightly_batch''');
SELECT dblink_exec('root', 'LOCK TABLE lock_tree_st IN ACCESS EXCLUSIVE MODE');

SELECT dblink_send_query('w1', 'SET application_name = ''api_a''; SELECT count(*) FROM lock_tree_st');
SELECT dblink_send_query('w2', 'SET application_name = ''api_b''; SELECT count(*) FROM lock_tree_st');

DO $wait$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a
               JOIN lock_tree_st_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

CREATE TEMP TABLE stmt AS SELECT * FROM lock_tree_statements();
\o
\unset QUIET

SELECT plan(11);   -- 6 run either way, 5 more need pg_stat_statements

SELECT has_function('lock_tree_statements', 'lock_tree_statements() exists');

-- ------------------------------------------------------------------ works with or without pgss

-- The reason this function is plpgsql rather than SQL. A SQL function naming
-- pg_stat_statements directly fails at CREATE EXTENSION time on a server without it, which
-- would make an optional feature mandatory; the reference has to be inside an EXECUTE.
SELECT is((SELECT count(*) FROM stmt)::int, 1,
          'one row per root blocker, whether or not pg_stat_statements is loaded');

SELECT is((SELECT root_pid FROM stmt),
          (SELECT pid FROM lock_tree_st_pids WHERE name = 'root'),
          'and the root is the session holding the lock');

SELECT is((SELECT application_name FROM stmt), 'nightly_batch',
          'named by application_name, so the row is readable without cross-referencing pids');

SELECT is((SELECT blocked_sessions FROM stmt)::bigint, 2::bigint,
          'with the number of sessions it blocks, matching lock_tree_wide()');

SELECT is((SELECT blocked_sessions FROM stmt),
          (SELECT blocked_sessions FROM lock_tree_wide()
           WHERE root_pid = (SELECT pid FROM lock_tree_st_pids WHERE name = 'root')),
          'and agreeing with lock_tree_wide() on that count');

-- ------------------------------------------------------------------ the pgss-dependent half

\if :have_pgss

-- The join itself. Every root with a query_id finds a matching pg_stat_statements row, because
-- the root's current statement is one it has run before.
SELECT ok((SELECT query_id FROM stmt) IS NOT NULL,
          'the root has a query_id, so the join has a key to follow');

SELECT ok((SELECT statement FROM stmt) IS NOT NULL,
          'and pg_stat_statements knows that queryid, so the statement text is filled in');

SELECT ok((SELECT calls FROM stmt) >= 1,
          'with a call count, which is what makes this a cost figure rather than a lookup');

-- The measured limitation, pinned so it cannot regress into a claim the function cannot keep.
SELECT is((SELECT count(*) FROM lock_tree
           WHERE depth > 0 AND wait_event_type = 'Lock'
             AND pid IN (SELECT pid FROM lock_tree_st_pids WHERE name IN ('w1','w2')))::int, 2,
          'both waiters are blocked, as the join setup intended');

SELECT ok((SELECT bool_and(query_id IS NULL) FROM pg_stat_activity
           WHERE pid IN (SELECT pid FROM lock_tree_st_pids WHERE name IN ('w1','w2'))
             AND wait_event_type = 'Lock'),
          'and both have a NULL query_id while blocked: the documented limitation is real');

\else

SELECT skip('pg_stat_statements is not in shared_preload_libraries, so the join cannot be exercised '
         || 'here. The degradation path above is still tested.', 5);

\endif

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT dblink_exec('root', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_st_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT s.pid FROM lock_tree_st_pids s
           JOIN pg_stat_activity a ON a.pid = s.pid LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE conn text; BEGIN
  FOREACH conn IN ARRAY ARRAY['root','w1','w2'] LOOP
    BEGIN PERFORM dblink_disconnect(conn); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_st_pids;
DROP TABLE lock_tree_st;
\o
\unset QUIET