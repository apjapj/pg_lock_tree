-- test/08_wide.sql: the wide queue, aggregated.
--
-- test/01_lock_tree.sql covers a five-session chain, which is small enough to read in full.
-- That is the point of a tree: for one incident, every line is worth reading. It stops being
-- true as the queue widens. At sixty sessions behind two roots, an operator's questions are
-- which root is worst, how many sessions each one holds up, and whether anything is a chain
-- rather than a flat queue, and none of those need the other fifty-five lines.
--
-- lock_tree_wide() answers them in one row per root. lock_tree_summary() answers "is anything
-- blocked at all" in one row, which is what a dashboard cell or an alert test needs.
--
-- Both must agree with lock_tree, not approximate it. That is what most of this file checks:
-- the aggregate is a different shape of the same facts, and a wide form that quietly
-- disagrees with the tree it summarises would be worse than no wide form.
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

DROP TABLE IF EXISTS lock_tree_wd;
DROP TABLE IF EXISTS lock_tree_wd2;
DROP TABLE IF EXISTS lock_tree_wd_pids;
-- Two tables, so two roots. One table with two ACCESS EXCLUSIVE requests queued against it
-- would give one root and one waiter, not two heads of the queue: only the first request gets
-- in and the second queues behind it. SHARE mode is worse still, since it is compatible with
-- itself and with a plain SELECT, so nothing blocks at all.
CREATE TABLE lock_tree_wd (id int);
CREATE TABLE lock_tree_wd2 (id int);
CREATE TABLE lock_tree_wd_pids (name text primary key, pid int);

CREATE TEMP TABLE wd_names AS
SELECT 'r1' AS n
UNION ALL SELECT 'r2'
UNION ALL SELECT 'w' || i FROM generate_series(1,40) i
UNION ALL SELECT 'x' || i FROM generate_series(1,15) i;

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM wd_names;

INSERT INTO lock_tree_wd_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM wd_names;

-- dblink_exec runs in autocommit, and LOCK TABLE is only valid inside a transaction.
SELECT dblink_exec('r1', 'BEGIN');
SELECT dblink_exec('r1', 'SET application_name = ''nightly_reconciliation''');
SELECT dblink_exec('r1', 'LOCK TABLE lock_tree_wd IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('r2', 'BEGIN');
SELECT dblink_exec('r2', 'SET application_name = ''reporting_rollup''');
SELECT dblink_exec('r2', 'LOCK TABLE lock_tree_wd2 IN ACCESS EXCLUSIVE MODE');

-- Queued in two batches with a pause between. One statement issuing 55 send_query calls is
-- slow to return, and the wait loop below gets no chance to observe anything until it does.
DO $send$
DECLARE i int;
BEGIN
  FOR i IN 1..40 LOOP
    PERFORM dblink_send_query('w' || i, format(
      'SET application_name = ''zz_api_worker_%s''; SELECT count(*) FROM lock_tree_wd',
      lpad(i::text, 2, '0')));
  END LOOP;
  PERFORM pg_sleep(0.5);
  FOR i IN 1..15 LOOP
    PERFORM dblink_send_query('x' || i, format(
      'SET application_name = ''zz_report_read_%s''; SELECT count(*) FROM lock_tree_wd2',
      lpad(i::text, 2, '0')));
  END LOOP;
END
$send$;

DO $wait$
BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a
               JOIN lock_tree_wd_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') >= 55;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

CREATE TEMP TABLE wide AS SELECT * FROM lock_tree_wide();
CREATE TEMP TABLE summ AS SELECT * FROM lock_tree_summary();
CREATE TEMP TABLE tree AS
SELECT root_pid, depth, pid, state, waiting_for FROM lock_tree;
\o
\unset QUIET

SELECT plan(20);

-- ------------------------------------------------------------------ existence

SELECT has_function('lock_tree_wide', 'lock_tree_wide() exists');
SELECT has_function('lock_tree_summary', 'lock_tree_summary() exists');

-- ------------------------------------------------------------------ shape of the queue

SELECT is((SELECT count(*) FROM tree)::int, 57, 'the wide chain has 57 rows: 2 roots and 55 waiters');
SELECT is((SELECT roots FROM summ)::int, 2, 'and lock_tree_summary() counts 2 roots');
SELECT is((SELECT blocked_sessions FROM summ)::int, 55, 'and 55 blocked sessions');

-- ------------------------------------------------------------------ the aggregate

SELECT is((SELECT count(*) FROM wide)::int, 2, 'lock_tree_wide() returns one row per root, not per session');

SELECT is((SELECT blocked_sessions FROM wide ORDER BY blocked_sessions DESC LIMIT 1)::bigint, 40::bigint,
          'the worse of the two roots is reported as blocking 40 sessions');

-- The waiters' names sort AFTER the roots', deliberately. Until 1.1.15 lock_tree_wide() took
-- max(application_name) over the whole tree, and this assertion passed only because the waiters
-- were named api_worker_N, which sorts before nightly_reconciliation.
SELECT is((SELECT application_name FROM wide ORDER BY blocked_sessions DESC LIMIT 1),
          'nightly_reconciliation',
          'and the root is named by ITS application_name, not by a waiter''s that sorts later');

SELECT is((SELECT state FROM wide ORDER BY blocked_sessions DESC LIMIT 1), 'idle in transaction',
          'the state is the ROOT''s state, not a waiter''s: this is the bug that would show '
          || 'if state were taken with max() over the whole chain');

SELECT matches((SELECT first_waiting_for FROM wide ORDER BY blocked_sessions DESC LIMIT 1),
               '^AccessShareLock on lock_tree_wd2?$',
               'what the waiters are waiting for is carried through, so the mode and relation '
               || 'are readable without opening the tree');

SELECT is((SELECT array_length(wait_events, 1) >= 1 FROM wide ORDER BY blocked_sessions DESC LIMIT 1),
          true, 'the wait events behind the root are listed');

-- ------------------------------------------------------------------ agreement with the tree

-- The important property. Every number in the wide form must be derivable from lock_tree, and
-- the roots must be the same pids. A wide form that disagrees with the tree it summarises is
-- worse than none at all, because it looks authoritative.
SELECT is((SELECT count(*) FROM wide w
           WHERE w.root_pid NOT IN (SELECT DISTINCT root_pid FROM tree))::int, 0,
          'every root in the wide form is a root_pid that appears in the tree');

SELECT is((SELECT count(*) FROM (
             SELECT w.root_pid
             FROM wide w JOIN tree t ON t.root_pid = w.root_pid
             GROUP BY w.root_pid, w.blocked_sessions
             HAVING w.blocked_sessions <> count(*) FILTER (WHERE t.depth > 0)
           ) d)::int, 0,
          'and every blocked_sessions count matches a count over the tree');

SELECT is((SELECT count(*) FROM (
             SELECT w.root_pid
             FROM wide w JOIN tree t ON t.root_pid = w.root_pid
             GROUP BY w.root_pid, w.max_depth
             HAVING w.max_depth <> max(t.depth)
           ) d)::int, 0,
          'and every max_depth matches the deepest chain under that root');

SELECT is((SELECT sum(blocked_sessions) FROM wide)::bigint, (SELECT blocked_sessions FROM summ),
          'the per-root counts add up to the summary''s total, so neither can drift');

SELECT is((SELECT max_depth FROM summ),
          (SELECT max(max_depth) FROM wide),
          'and the summary''s deepest chain is the widest root''s');

SELECT is((SELECT count(*) FROM wide w
           JOIN tree t ON t.root_pid = w.root_pid AND t.depth = 0
           WHERE w.state IS DISTINCT FROM t.state)::int, 0,
          'and every state matches the tree''s own depth-0 row');

-- ------------------------------------------------------------------ quiet database

\set QUIET 1
\o /dev/null
-- Roll the roots back FIRST, then wait. Waiting alone never terminates: the waiters are
-- blocked on locks the roots hold, so the tree stays full until the roots let go, and the
-- loop simply runs out of iterations after 10 seconds and the "quiet" assertions then measure
-- a queue that is still stuck. Which is exactly what they did the first time.
SELECT dblink_exec('r1', 'ROLLBACK');
SELECT dblink_exec('r2', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_wd_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;
CREATE TEMP TABLE quiet_summ AS SELECT * FROM lock_tree_summary();
CREATE TEMP TABLE quiet_wide AS SELECT count(*) AS n FROM lock_tree_wide();
\o
\unset QUIET

SELECT is((SELECT blocked_sessions FROM quiet_summ)::bigint, 0::bigint,
          'lock_tree_summary() on a quiet database reports 0 blocked, not no rows');

SELECT is((SELECT roots FROM quiet_summ)::bigint, 0::bigint, 'and 0 roots');

SELECT is((SELECT n FROM quiet_wide)::bigint, 0::bigint,
          'lock_tree_wide() returns no rows at all, which is right: there is nothing to rank');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT w.pid FROM lock_tree_wd_pids w
           JOIN pg_stat_activity a ON a.pid = w.pid LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
-- The loop variable is conn, not n: naming it n shadows the wd_names.n column inside the loop
-- body and PostgreSQL reports the reference as ambiguous.
DO $b$ DECLARE conn text; BEGIN
  FOR conn IN SELECT n FROM wd_names LOOP
    BEGIN PERFORM dblink_disconnect(conn); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_wd_pids;
DROP TABLE lock_tree_wd;
DROP TABLE lock_tree_wd2;
\o
\unset QUIET