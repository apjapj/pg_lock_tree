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
\echo '--- standard query: can it see a blocker that has no pg_locks pid? ---'
\i 01_standard_query.sql

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