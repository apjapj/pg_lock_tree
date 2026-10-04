-- s8_many_roots.sql: five blockers at once, which is the case lock_tree_wide() exists for.
--
-- s4_wide_queue.sql already covers a wide queue: sixty sessions behind ONE idle transaction. That
-- is the shape the abbreviation work was aimed at, and lock_tree_text_short() handles it.
--
-- What s4 does not cover is a queue that is wide AND has several heads. Then the question is no
-- longer "which root is worst" with one answer, but "which of my five roots is the worst one", and
-- answering it means reading every line of the tree. This scenario builds that, and shows the
-- aggregate replacing a 66-row tree with 5 rows.
--
-- Five tables rather than one, for the reason s2 and s8 both depend on: two ACCESS EXCLUSIVE
-- requests queued against the SAME table do not give two heads of the queue. The first gets in
-- and the second becomes its waiter, so there is one root and one chain. A root per table is the
-- only way to get genuine parallelism.
--
-- The published CTE is run here too, as everywhere else in this suite, so the coverage row at the
-- end is measured the same way as the other seven scenarios.

\set ON_ERROR_STOP 1
\pset border 2
\set QUIET 1
\o /dev/null
CREATE EXTENSION IF NOT EXISTS dblink;

DROP TABLE IF EXISTS s8_t1; DROP TABLE IF EXISTS s8_t2; DROP TABLE IF EXISTS s8_t3;
DROP TABLE IF EXISTS s8_t4; DROP TABLE IF EXISTS s8_t5;
DROP TABLE IF EXISTS s8_pids; DROP TABLE IF EXISTS s8_tags;
-- Five tables so five roots. SHARE would be compatible with itself and with a plain SELECT, so
-- nothing would block at all; ACCESS EXCLUSIVE conflicts with everything.
CREATE TABLE s8_t1 (id int); CREATE TABLE s8_t2 (id int); CREATE TABLE s8_t3 (id int);
CREATE TABLE s8_t4 (id int); CREATE TABLE s8_t5 (id int);
CREATE TABLE s8_pids (name text PRIMARY KEY, pid int);
CREATE TABLE s8_tags (n text PRIMARY KEY, app text, tbl text);

CREATE TEMP TABLE s8_names AS
SELECT 'r' || i AS n, 'batch_' || i AS app, 's8_t' || i AS tbl
FROM generate_series(1,5) i
UNION ALL
SELECT 'w' || i, 'api_worker_' || lpad(i::text,2,'0'), NULL
FROM generate_series(1,66) i;

-- The roots are the rows with a table. application_name is set for the waiters too, so
-- filtering on that would select all 71 sessions and the loop below would try to take a
-- lock on a waiter's connection.
INSERT INTO s8_tags SELECT n, app, tbl FROM s8_names WHERE tbl IS NOT NULL;
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM s8_names;

INSERT INTO s8_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM s8_names;

-- Each root takes its own table and goes idle in its transaction.
DO $roots$
DECLARE r record;
BEGIN
  FOR r IN SELECT n, app, tbl FROM s8_tags LOOP
    PERFORM dblink_exec(r.n, 'BEGIN');
    PERFORM dblink_exec(r.n, format('SET application_name = %L', r.app));
    PERFORM dblink_exec(r.n, format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', r.tbl));
  END LOOP;
END
$roots$;

-- 66 waiters spread unevenly across the five roots, so the ranking is not a tie and the "which
-- is worst" question has a real answer: 30 on root 1 down to 3 on root 5.
--
-- One query per waiter, each targeting the table of (n-1) % 5 + 1. Queued with a short pause
-- between them: one statement issuing 66 send_query calls is slow to return, and the wait loop
-- below gets no chance to observe anything until it does.
DO $feed$
DECLARE w record;
BEGIN
  FOR w IN SELECT n, app, (substr(n, 2)::int) AS i FROM s8_names WHERE n LIKE 'w%' LOOP
    -- One statement per connection, carrying both the SET and the query. Two send_query calls on
    -- the same connection fail with "another command is already in progress", which is the dblink
    -- one-command-per-connection rule and cost this scenario its first two attempts.
    -- Unevenly on purpose: 30 waiters on root 1, then 18, 10, 5 and 3. A modulo would give
    -- 14/13/13/13/13, which is nearly a tie and makes the ranking the aggregate exists for look
    -- like it does nothing.
    PERFORM dblink_send_query(w.n, format(
      'SET application_name = %L; SELECT count(*) FROM s8_t%s', w.app,
      CASE WHEN w.i <= 30 THEN 1 WHEN w.i <= 48 THEN 2
           WHEN w.i <= 58 THEN 3 WHEN w.i <= 63 THEN 4 ELSE 5 END));
    PERFORM pg_sleep(0.005);
  END LOOP;
END
$feed$;

DO $w$ BEGIN
  FOR i IN 1..400 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a JOIN s8_pids USING (pid)
               WHERE a.wait_event_type = 'Lock') >= 66;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$w$;
\o
\unset QUIET

\echo ''
\echo '--- five roots, sixty-six waiters: one row each ---'
SELECT root_pid, application_name AS root, state, blocked_sessions, max_depth, longest_wait
FROM lock_tree_wide() ORDER BY blocked_sessions DESC;

\echo ''
\echo '--- the same thing as a tree, which is the problem ---'
SELECT count(*) AS tree_lines, count(DISTINCT root_pid) AS roots
FROM lock_tree WHERE depth > 0;

\echo ''
\echo '--- one row for the whole queue ---'
SELECT * FROM lock_tree_summary();

\echo ''
\echo '--- the tree itself, abbreviated, first few and last few ---'
SELECT * FROM lock_tree_text_short(100) OFFSET 0 LIMIT 4;
SELECT * FROM lock_tree_text_short(100) OFFSET 64;

\echo ''
\echo '--- what each root is holding, from the pg_stat_statements join ---'
\echo '     (empty without pg_stat_statements, which is the point: the roots are reported either way)'
SELECT application_name, blocked_sessions, left(statement, 60) AS statement, calls, mean_exec_time
FROM lock_tree_statements() ORDER BY blocked_sessions DESC;

\echo ''
\echo '--- and the published CTE on the same incident ---'
\i 01_standard_query.sql

\echo ''
\echo '--- coverage, all three, the same measurement the other scenarios use ---'
WITH waiting AS (SELECT DISTINCT pid FROM pg_stat_activity WHERE wait_event_type='Lock')
SELECT (SELECT count(*) FROM waiting) AS actually_waiting,
       (SELECT count(*) FROM std_result WHERE blocked_pid IN (SELECT pid FROM waiting)) AS reported_by_standard,
       (SELECT count(*) FROM lock_tree WHERE pid IN (SELECT pid FROM waiting)) AS reported_by_pg_lock_tree;

\echo ''
\echo '--- clearing all five at once ---'
SELECT * FROM lock_tree_actions();

\set QUIET 1
\o /dev/null
-- Roll back rather than terminate: these are idle-in-transaction roots holding five separate
-- tables, and a rollback releases all of them in one statement and leaves no aborted transaction
-- behind for the next run's tree to report.
DO $r$
DECLARE r record;
BEGIN
  FOR r IN SELECT n FROM s8_tags LOOP
    BEGIN PERFORM dblink_exec(r.n, 'ROLLBACK'); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$r$;
DO $d$ BEGIN
  FOR i IN 1..400 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s8_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT s.pid FROM s8_pids s JOIN pg_stat_activity a ON a.pid = s.pid LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM s8_names LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s8_tags; DROP TABLE s8_pids;
DROP TABLE s8_t1; DROP TABLE s8_t2; DROP TABLE s8_t3; DROP TABLE s8_t4; DROP TABLE s8_t5;
\o
\unset QUIET

\echo ''
\echo '--- sessions left behind ---'
SELECT count(*) AS s8_sessions_left FROM pg_stat_activity
WHERE application_name LIKE 'api_worker_%' OR application_name LIKE 'batch_%';