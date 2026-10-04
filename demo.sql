-- demo.sql — pg_lock_tree in action, on a throwaway database.
--
-- Rebuilds the nightly-batch incident from the README using dblink, so you can watch
-- lock_tree, lock_tree_roots() and lock_tree_text() work on a real blocking chain, then
-- watch the queue drain once you act on it.
--
--   psql -X -f demo.sql          as a superuser; needs the dblink contrib module
--
-- Safe to re-run: everything it creates is terminated and dropped at the end.
-- Mechanical output (connecting, BEGIN, UPDATE 1) is suppressed — only the
-- interesting results are shown.

\set ON_ERROR_STOP 1
\pset border 2

\echo ''
\echo '##############################################################################'
\echo '# 0. Install'
\echo '##############################################################################'
\set QUIET 1
\o /dev/null
CREATE EXTENSION IF NOT EXISTS pg_lock_tree;
CREATE EXTENSION IF NOT EXISTS dblink;
DROP TABLE IF EXISTS demo_ledger; DROP TABLE IF EXISTS demo_pids;
DROP TABLE IF EXISTS demo_x; DROP TABLE IF EXISTS demo_y;
\o
\unset QUIET

SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_lock_tree';

\echo ''
\echo '##############################################################################'
\echo '# 1. A quiet database: the tree is empty'
\echo '##############################################################################'
SELECT count(*) AS sessions_in_tree FROM lock_tree;

\echo ''
\echo '##############################################################################'
\echo '# 2. Build the incident'
\echo '##############################################################################'
\echo ' A nightly batch holds a row lock, then sits idle in its transaction.'
\echo ' An ALTER TABLE queues behind it, then ordinary reads queue behind the ALTER.'
\echo ''

\set QUIET 1
\o /dev/null
CREATE TABLE demo_ledger (id int primary key, amount numeric);
INSERT INTO demo_ledger VALUES (1, 100), (2, 200), (3, 300);
CREATE TABLE demo_pids (name text PRIMARY KEY, pid int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['a','b','c','d','e']) AS n;
INSERT INTO demo_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['a','b','c','d','e']) AS n;

-- A: the culprit. takes the lock, then goes idle with the transaction open.
SELECT dblink_exec('a', 'BEGIN');
SELECT dblink_exec('a', 'SET application_name = ''nightly_batch''');
SELECT dblink_exec('a', 'UPDATE demo_ledger SET amount = amount WHERE id = 1');

-- B: DDL, which queues behind A.
SELECT dblink_send_query('b', 'BEGIN; SET application_name=''schema_change''; ALTER TABLE demo_ledger ADD COLUMN IF NOT EXISTS note text; COMMIT');

-- C, D, E: plain reads, which queue behind B rather than straight at A.
SELECT pg_sleep(0.4);
SELECT dblink_send_query('c', 'SET application_name=''report-c''; SELECT sum(amount) FROM demo_ledger');
SELECT dblink_send_query('d', 'SET application_name=''report-d''; SELECT * FROM demo_ledger ORDER BY id LIMIT 10');
SELECT dblink_send_query('e', 'SET application_name=''report-e''; SELECT count(*) FROM demo_ledger');

DO $w$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM demo_pids)
                 AND wait_event_type = 'Lock') >= 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$w$;
\o
\unset QUIET

SELECT p.name AS sess, a.pid, a.application_name, a.state
FROM demo_pids p JOIN pg_stat_activity a USING (pid)
ORDER BY p.name;

\echo ''
\echo '##############################################################################'
\echo '# 3. lock_tree_text() — the queue, top to bottom'
\echo '##############################################################################'
\echo ' Note reads (report-c/d/e) sit under the ALTER TABLE, not under the batch:'
\echo ' they queue behind whoever is ahead of them in the lock queue.'
\echo ''
SELECT * FROM lock_tree_text();

\echo ''
\echo '##############################################################################'
\echo '# 4. lock_tree — who blocks whom, and for how long'
\echo '##############################################################################'
SELECT p.name AS sess, t.depth, t.state,
       coalesce(t.waiting_for, '-') AS waiting_for,
       coalesce(t.wait_age::text, '-') AS waited,
       coalesce(t.blocked_by::text, '{}') AS blocked_by
FROM lock_tree t JOIN demo_pids p USING (pid)
ORDER BY t.root_pid, t.path;

\echo ''
\echo '##############################################################################'
\echo '# 5. lock_tree_roots() — the one session to act on'
\echo '##############################################################################'
\echo ' One root here: the idle batch, blocking 4 sessions. Everything else is a symptom.'
\echo ''
SELECT root_pid, coalesce(application_name, '-') AS app, state,
       blocked_sessions, max_depth, longest_wait, suggested_action
FROM lock_tree_roots() ORDER BY blocked_sessions DESC, root_pid;

\echo ''
\echo '##############################################################################'
\echo '# 6. Act on it — terminate the idle batch'
\echo '##############################################################################'
\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(root_pid)
FROM lock_tree_roots() WHERE state LIKE 'idle in transaction%';
DO $d$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM demo_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$d$;
\o
\unset QUIET

SELECT count(*) AS sessions_left_in_tree FROM lock_tree;

\echo ''
\echo '##############################################################################'
\echo '# 7. Bonus: a deadlock has no head of the queue'
\echo '##############################################################################'
\echo ' Two sessions each grab one table, then each asks for the other''s.'
\echo ' Nobody is "the blocker" — so every session in the cycle is listed as a root.'
\echo ''

\set QUIET 1
\o /dev/null
CREATE TABLE demo_x (id int);
CREATE TABLE demo_y (id int);
SELECT dblink_connect('f', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_connect('g', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('f', 'SET deadlock_timeout = ''15s''');
SELECT dblink_exec('g', 'SET deadlock_timeout = ''15s''');
SELECT dblink_exec('f', 'BEGIN');
SELECT dblink_exec('g', 'BEGIN');
SELECT dblink_exec('f', 'LOCK TABLE demo_x IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('g', 'LOCK TABLE demo_y IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('f', 'LOCK TABLE demo_y IN ACCESS EXCLUSIVE MODE');
SELECT pg_sleep(0.3);
SELECT dblink_send_query('g', 'LOCK TABLE demo_x IN ACCESS EXCLUSIVE MODE');
DO $c$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE wait_event_type = 'Lock' AND query LIKE 'LOCK TABLE demo_%') = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$c$;
\o
\unset QUIET

\echo ' Both are hard-blocked on each other. blocked_by shows the cycle:'
SELECT pid, root_pid, depth, state, blocked_by, waiting_for
FROM lock_tree ORDER BY pid;

\echo ' And lock_tree_roots() lists both, with a cancel suggestion for each:'
SELECT root_pid, state, suggested_action FROM lock_tree_roots() ORDER BY root_pid;

\echo ''
\echo '##############################################################################'
\echo '# 8. Cleanup'
\echo '##############################################################################'
\set QUIET 1
\o /dev/null
-- Collect the backend PIDs FIRST, then terminate one per statement.
--
-- Doing both in one statement (e.g. FOR p IN SELECT ... dblink(...) LOOP
-- pg_terminate_backend(p.pid)) kills the dblink connection while the cursor is still
-- fetching from it: "server closed the connection unexpectedly", and with
-- ON_ERROR_STOP the script aborts before cleaning up.
--
-- Terminate rather than cancel: a cancelled session stays connected holding an aborted
-- transaction, which would still show up in the next run's tree.
CREATE TEMP TABLE demo_kill (pid int);
DO $collect$
DECLARE n text; p int;
BEGIN
  FOREACH n IN ARRAY ARRAY['a','b','c','d','e','f','g'] LOOP
    BEGIN
      SELECT q INTO p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(q int);
      IF p IS NOT NULL THEN INSERT INTO demo_kill VALUES (p); END IF;
    EXCEPTION WHEN OTHERS THEN NULL;   -- already gone
    END;
  END LOOP;
END
$collect$;

DO $kill$
DECLARE p int;
BEGIN
  FOR p IN SELECT pid FROM demo_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$kill$;

DO $drain$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM pg_stat_activity
                          WHERE query LIKE '%demo_%' OR query LIKE 'LOCK TABLE demo_%');
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;

DO $bye$
DECLARE n text;
BEGIN
  FOREACH n IN ARRAY ARRAY['a','b','c','d','e','f','g'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$bye$;

DROP TABLE IF EXISTS demo_pids;
DROP TABLE IF EXISTS demo_ledger;
DROP TABLE IF EXISTS demo_x;
DROP TABLE IF EXISTS demo_y;
DROP TABLE IF EXISTS demo_kill;
\o
\unset QUIET

-- Count only dblink sessions, i.e. exclude this psql session itself: its own query text
-- contains the LIKE patterns being searched for, so a naive count always reports 1.
SELECT count(*) AS demo_sessions_left_behind
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND (query LIKE 'BEGIN;%demo_ledger%' OR query LIKE 'LOCK TABLE demo_%'
       OR query LIKE 'SET application_name=%demo%');