-- s3_row_locks.sql: contention that is NOT a table lock.
--
-- The case where pg_locks shows no relation at all: two sessions UPDATE the same row, so the
-- wait is a tuple lock plus a transaction id. Anyone reading pg_locks for `relation` sees
-- nothing useful. This is the most common real lock complaint after "idle in transaction",
-- and the one where a relation-centric mental model falls over.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 3: row-level contention, not a table lock ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s3_t;
DROP TABLE IF EXISTS s3_pids;
CREATE TABLE s3_t (id int primary key, v text);
INSERT INTO s3_t SELECT g, 'v'||g FROM generate_series(1,5) g;
CREATE TABLE s3_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['w1','w2','w3']) AS n;
INSERT INTO s3_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['w1','w2','w3']) AS n;

-- W1 takes a row lock on id=1 and stops short of committing.
SELECT dblink_exec('w1','BEGIN');
SELECT dblink_exec('w1','SET application_name = ''checkout_w1''');
SELECT dblink_exec('w1','UPDATE s3_t SET v = ''w1'' WHERE id = 1');

-- W2 wants the same row. This is a tuple lock: pg_locks.relation is NULL.
SELECT dblink_send_query('w2',
  'SET application_name=''checkout_w2''; UPDATE s3_t SET v = ''w2'' WHERE id = 1');
SELECT pg_sleep(0.4);

-- W3 is a third caller for the same row, queued behind W2.
SELECT dblink_send_query('w3',
  'SET application_name=''checkout_w3''; UPDATE s3_t SET v = ''w3'' WHERE id = 1');

DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s3_pids) AND wait_event_type='Lock') >= 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

\echo ''
\echo '--- the locks as pg_locks reports them: no relation, so "which table?" is unanswerable ---'
SELECT l.pid, l.locktype, coalesce(l.relation::regclass::text,'-') AS relation,
       l.mode, l.granted
FROM pg_locks l WHERE l.pid IN (SELECT pid FROM s3_pids) ORDER BY l.granted, l.pid;

\echo ''
\echo '--- pg_lock_tree: it names the row, and the chain order ---'
SELECT * FROM lock_tree_text();

\echo ''
\echo '--- pg_lock_tree: waiting_for shows the transaction wait, not a table ---'
SELECT p.tag, t.depth, t.wait_event, t.waiting_for, t.blocked_by
FROM lock_tree t JOIN s3_pids p USING (pid) ORDER BY t.root_pid, t.path;

\echo ''
\echo '--- the action ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- standard query: how does it represent a lock with no relation? ---'
\i 01_standard_query.sql

\set QUIET 1
\o /dev/null
CREATE TEMP TABLE s3_kill AS SELECT pid FROM s3_pids;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s3_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s3_kill));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['w1','w2','w3'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s3_pids; DROP TABLE s3_t;
\o
\unset QUIET
SELECT count(*) AS s3_sessions_left FROM pg_stat_activity
WHERE application_name LIKE 'checkout_%';