-- s1_nightly_batch.sql: the baseline case, and the one the README shows.
--
-- One culprit holds a row lock and goes idle in its transaction; an ALTER TABLE queues
-- behind it; ordinary reads queue behind the ALTER. Five sessions, one root.
--
-- This is the case every tool handles, and the published recursive CTE handles it fine.
-- Included as the reference point: if a later scenario looks good only because this one
-- is weak, the comparison is worthless.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 1: one culprit, four waiters ==='

-- ---------------------------------------------------------------- setup
\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s1_t;
DROP TABLE IF EXISTS s1_pids;
CREATE TABLE s1_t (id int primary key, v text);
INSERT INTO s1_t VALUES (1,'a'),(2,'b'),(3,'c');
CREATE TABLE s1_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['s1a','s1b','s1c','s1d','s1e']) AS n;
INSERT INTO s1_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['s1a','s1b','s1c','s1d','s1e']) AS n;

SELECT dblink_exec('s1a','BEGIN');
SELECT dblink_exec('s1a','SET application_name = ''nightly_batch''');
SELECT dblink_exec('s1a','UPDATE s1_t SET v = v WHERE id = 1');

SELECT dblink_send_query('s1b','BEGIN; SET application_name=''deploy_ddl''; ALTER TABLE s1_t ADD COLUMN IF NOT EXISTS note text; COMMIT');
SELECT pg_sleep(0.4);
SELECT dblink_send_query('s1c','SET application_name=''report-c''; SELECT count(*) FROM s1_t');
SELECT dblink_send_query('s1d','SET application_name=''report-d''; SELECT * FROM s1_t ORDER BY id');
SELECT dblink_send_query('s1e','SET application_name=''report-e''; SELECT sum(id) FROM s1_t');
DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s1_pids) AND wait_event_type='Lock') >= 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

-- ---------------------------------------------------------------- look
\echo ''
\echo '--- the incident, flat, as pg_stat_activity shows it ---'
SELECT p.tag, a.application_name, a.state, coalesce(a.wait_event_type,'-') AS waiting
FROM s1_pids p JOIN pg_stat_activity a USING (pid) ORDER BY p.tag;

\echo ''
\echo '--- pg_lock_tree: lock_tree_text() ---'
SELECT * FROM lock_tree_text();

\echo ''
\echo '--- pg_lock_tree: lock_tree_text_short() (same tree, abbreviated) ---'
SELECT * FROM lock_tree_text_short();

\echo ''
\echo '--- pg_lock_tree: lock_tree_roots() ---'
SELECT root_pid, application_name, state, blocked_sessions, max_depth, suggested_action
FROM lock_tree_roots();

\echo ''
\echo '--- pg_lock_tree: lock_tree_actions() ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- the published recursive CTE, on the same data ---'
\i 01_standard_query.sql

-- ---------------------------------------------------------------- teardown
\set QUIET 1
\o /dev/null
CREATE TEMP TABLE s1_kill AS SELECT pid FROM s1_pids;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s1_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s1_kill));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['s1a','s1b','s1c','s1d','s1e'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s1_pids; DROP TABLE s1_t;
\o
\unset QUIET
SELECT count(*) AS s1_sessions_left FROM pg_stat_activity
WHERE application_name LIKE 'report-%'
   OR application_name IN ('nightly_batch','deploy_ddl');