-- s7_prepared.sql: the blocker is not a session at all.
--
-- A prepared transaction holds its locks until COMMIT PREPARED or ROLLBACK PREPARED. It has
-- no backend, so it is not in pg_stat_activity, and no PID, so it has no pg_locks row keyed
-- to a session either. The waiters are real, the blocker is invisible, and if the client
-- that prepared it has gone home the locks can sit there indefinitely.
--
-- This is the case that decides whether a tool is trustworthy. Everything else is "find the
-- session that is causing this"; this is "there is no session".

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 7: a prepared transaction holding locks with no session behind it ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s7_t;
DROP TABLE IF EXISTS s7_pids;
CREATE TABLE s7_t (id int primary key, v text);
INSERT INTO s7_t SELECT g,'v'||g FROM generate_series(1,3) g;
CREATE TABLE s7_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['prep','wait1','wait2']) AS n;
INSERT INTO s7_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['prep','wait1','wait2']) AS n;

-- PREPARE needs max_prepared_transactions > 0. The pg-test images set it; a stock postgres
-- image does not, and this scenario errors there with "prepared transactions are disabled".
SELECT dblink_exec('prep','BEGIN');
SELECT dblink_exec('prep','LOCK TABLE s7_t IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('prep','PREPARE TRANSACTION ''s7_stranded''');
SELECT dblink_send_query('wait1','SET application_name=''api_wait_1''; SELECT count(*) FROM s7_t');
SELECT pg_sleep(0.4);
SELECT dblink_send_query('wait2','SET application_name=''api_wait_2''; SELECT * FROM s7_t');

DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s7_pids) AND wait_event_type='Lock') >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

\echo ''
\echo '--- the prepared transaction exists, and owns no session ---'
SELECT gid, prepared, owner, database FROM pg_prepared_xacts;
\echo '   ... and it is in no pg_stat_activity row at all:'
SELECT count(*) AS matching_activity_rows
FROM pg_stat_activity WHERE query LIKE '%PREPARE TRANSACTION%';

\echo ''
\echo '--- pg_locks shows the granted lock, but with a NULL pid ---'
SELECT pid, locktype, relation::regclass::text AS relation, mode, granted
FROM pg_locks WHERE relation = 's7_t'::regclass ORDER BY granted;

\echo ''
\echo '--- pg_lock_tree: the waiters are attributed to pid 0 ---'
SELECT * FROM lock_tree_text();

\echo ''
\echo '--- pid 0 is the prepared transaction, labelled as such ---'
SELECT pid, root_pid, depth, state, blocked_by, waiting_for
FROM lock_tree ORDER BY root_pid, path;

\echo ''
\echo '--- and it is offered as an actionable root ---'
SELECT root_pid, state, blocked_sessions, suggested_action FROM lock_tree_roots();

\echo ''
\echo '--- lock_tree_actions(): the written description names ROLLBACK PREPARED, not a cancel ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- lock_tree_command(): no statement at all, because pid 0 is not a backend ---'
\echo '     (zero rows is the correct answer here, and the reason is worth stating:'
\echo '      pg_cancel_backend(0) returns false and warns "PID 0 is not a PostgreSQL backend'
\echo '      process", so 0.2 emitted a suggestion that could never have worked.)'
SELECT count(*) AS statements_offered FROM lock_tree_command();

\echo ''
\echo '--- standard query: can it see a blocker that has no pg_locks pid? ---'
\i 01_standard_query.sql

-- ---------------------------------------------------------------- more than one at once
--
-- Everything above is ONE prepared transaction, and one has always worked: there is a single
-- blocker, so pid 0 is the only pid 0 and grouping on it cannot merge anything. More than one is
-- where 0.7 was wrong, and wrong in the way that matters: not that it missed a session, but that
-- it reported a blast radius no single transaction held.
--
-- This section adds two more on fresh tables and deliberately does NOT roll back s7_stranded first,
-- so all three are prepared at once. One was enough to demonstrate the bug and three demonstrates
-- it better: 0.7 would report a single row claiming four blocked sessions, held by nothing that
-- exists. The 0.7 answer is computed below rather than quoted, so the comparison is measured rather
-- than remembered.

\set QUIET 1
\o /dev/null
-- Fresh tables, and specifically NOT s7_t: s7_stranded holds it for the rest of this file, so a
-- second prepared transaction locking it waits on the first forever, with no error and no output.
-- That is what the first attempt at this section did, and the scenario hung rather than failed.
DROP TABLE IF EXISTS s7_t2;
DROP TABLE IF EXISTS s7_t3;
CREATE TABLE s7_t2 (id int PRIMARY KEY, v text);
CREATE TABLE s7_t3 (id int PRIMARY KEY, v text);
INSERT INTO s7_t2 SELECT g, 'w' || g FROM generate_series(1,3) g;
INSERT INTO s7_t3 SELECT g, 'x' || g FROM generate_series(1,3) g;
DROP TABLE IF EXISTS s7_pids2;
CREATE TABLE s7_pids2 (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['prep2','prep3','wait3','wait4']) AS n;
INSERT INTO s7_pids2
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['prep2','prep3','wait3','wait4']) AS n;

-- Two more tables, because two ACCESS EXCLUSIVE requests queued against the SAME table do not give
-- two roots: the first gets in and the second becomes its waiter. A root per table is the only way
-- to get genuine parallelism, and that is true of prepared transactions as of anything else.
--
-- The lock is taken BEFORE preparing, or the prepared transaction holds nothing and blocks nobody.
SELECT dblink_exec('prep2', 'BEGIN');
SELECT dblink_exec('prep2', 'LOCK TABLE s7_t2 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('prep2', 'PREPARE TRANSACTION ''s7_second''');
SELECT dblink_exec('prep3', 'BEGIN');
SELECT dblink_exec('prep3', 'LOCK TABLE s7_t3 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('prep3', 'PREPARE TRANSACTION ''s7_third''');
SELECT dblink_send_query('wait3', 'SET application_name=''api_3''; SELECT count(*) FROM s7_t2');
SELECT dblink_send_query('wait4', 'SET application_name=''api_4''; SELECT count(*) FROM s7_t3');
DO $w2$ BEGIN
  FOR i IN 1..150 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity a JOIN s7_pids2 USING (pid)
               WHERE a.wait_event_type = 'Lock') >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w2$;
\o
\unset QUIET

\echo ''
\echo '=== the same trick with THREE prepared transactions at once, which is what 0.8 fixed ==='
\echo ''
\echo '--- three prepared transactions, no sessions, three tables held ---'
SELECT gid, prepared, owner FROM pg_prepared_xacts ORDER BY gid;

\echo ''
\echo '--- three roots, each naming the lock it holds. 0.7 merged all three into one row. ---'
SELECT depth, root_pid, root_object, pid
FROM lock_tree ORDER BY depth, root_object, pid;

\echo ''
\echo '--- the aggregate: three roots, and no root claiming more than it holds ---'
SELECT root_pid, root_object, blocked_sessions, max_depth FROM lock_tree_wide()
ORDER BY root_object;
SELECT blocked_sessions AS total_blocked, roots FROM lock_tree_summary();

\echo ''
\echo '--- and what 0.7 reported for this same incident, computed rather than remembered ---'
\echo '--- one row, GROUP BY root_pid alone, whose blocked_sessions was the sum of all three ---'
SELECT 1 AS roots_0_7_reported,
       count(*) FILTER (WHERE depth > 0) AS blocked_sessions_that_one_row_claimed,
       count(*) FILTER (WHERE depth = 0)  AS roots_0_8_reports_instead
FROM lock_tree;

\echo ''
\echo '--- the standard query on the same incident, for the record ---'
\i 01_standard_query.sql

\set QUIET 1
\o /dev/null
ROLLBACK PREPARED 's7_second';
ROLLBACK PREPARED 's7_third';
DO $d2$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s7_pids2));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d2$;
DO $k2$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s7_pids2 LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k2$;
DO $b2$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['prep2','prep3','wait3','wait4'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b2$;
DROP TABLE s7_pids2; DROP TABLE s7_t2; DROP TABLE s7_t3;
\o
\unset QUIET

\set QUIET 1
\o /dev/null
ROLLBACK PREPARED 's7_stranded';
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s7_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s7_pids LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['prep','wait1','wait2'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s7_pids; DROP TABLE s7_t;
\o
\unset QUIET
SELECT count(*) AS s7_sessions_left FROM pg_stat_activity WHERE application_name LIKE 'api_wait_%';