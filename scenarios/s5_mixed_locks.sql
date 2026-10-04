-- s5_mixed_locks.sql — locks that are not table locks at all.
--
-- Advisory locks, and the case where the wait is on something a DBA cannot name with a
-- table name. `pg_locks.relation` is NULL, so a relation-centric query returns either nothing
-- or something unhelpful, and "which table is it locking?" is the wrong question.
--
-- Advisory locks are the common real case: a deployment script takes pg_advisory_lock, a
-- worker takes the same one, and everything queues behind a lock that has no name in any
-- table. It also has no row in pg_blocking_pids for the *granted* side in a way a relation
-- query would find, which is why this scenario exists.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 5: advisory locks and waits with no relation ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s5_pids;
CREATE TABLE s5_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['dep','w1','w2','mon']) AS n;
INSERT INTO s5_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['dep','w1','w2','mon']) AS n;

-- chain A: a deploy script holds an advisory lock, two workers queue behind it.
--
-- pg_advisory_lock returns void, so neither a bare call nor a SELECT one will do through
-- dblink_exec, which refuses anything that would return rows. dblink_send_query is the right
-- tool anyway: the lock blocks, so we must not wait on it. The holder ends up idle inside its
-- open transaction, still holding the advisory lock — which is exactly the state this
-- scenario is about.
SELECT dblink_exec('dep','BEGIN');
SELECT dblink_exec('dep','SET application_name = ''deploy_migrate''');
SELECT dblink_send_query('dep','SELECT pg_advisory_lock(4242)');
DO $g$ BEGIN FOR i IN 1..50 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity a JOIN s5_pids p USING (pid)
             WHERE p.tag='dep' AND a.state='idle in transaction') = 1;
  PERFORM pg_sleep(0.1);
END LOOP; END $g$;

SELECT dblink_send_query('w1','SET application_name=''worker_one''; SELECT pg_advisory_lock(4242)');

-- chain B: a monitoring agent on a *different* advisory key, so there are two unrelated roots
SELECT dblink_exec('mon','BEGIN');
SELECT dblink_exec('mon','SET application_name = ''metrics_agent''');
SELECT dblink_send_query('mon','SELECT pg_advisory_lock(99)');
DO $g2$ BEGIN FOR i IN 1..50 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity a JOIN s5_pids p USING (pid)
             WHERE p.tag='mon' AND a.state='idle in transaction') = 1;
  PERFORM pg_sleep(0.1);
END LOOP; END $g2$;
SELECT dblink_send_query('w2','SET application_name=''vacuum_agent''; SELECT pg_advisory_lock(99)');

DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s5_pids) AND wait_event_type='Lock') >= 3;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

\echo ''
\echo '--- pg_locks: the relation column is NULL for all of these ---'
SELECT l.pid, l.locktype, coalesce(l.relation::regclass::text,'NULL') AS relation,
       coalesce(l.classid::regclass::text,'-') AS classid, l.objid, l.mode, l.granted
FROM pg_locks l
WHERE l.locktype = 'advisory'
ORDER BY l.granted, l.pid;

\echo ''
\echo '--- pg_lock_tree: waiting_for falls back to the locktype when there is no relation ---'
SELECT * FROM lock_tree_text();

\echo ''
\echo '--- and the view carries the advisory identifiers explicitly ---'
SELECT p.tag, t.depth, t.wait_event, t.waiting_for, t.blocked_by
FROM lock_tree t JOIN s5_pids p USING (pid) ORDER BY t.root_pid, t.path;

\echo ''
\echo '--- two independent roots, ranked ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- standard query: advisory locks join on classid/objid, which most copies of this ---'
\echo '    query do not include in the identity match, so they fall out entirely ---'
\i 01_standard_query.sql

\set QUIET 1
\o /dev/null
CREATE TEMP TABLE s5_kill AS SELECT pid FROM s5_pids;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s5_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s5_kill));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['dep','w1','w2','mon'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s5_pids;
\o
\unset QUIET
SELECT count(*) AS s5_sessions_left FROM pg_stat_activity
WHERE application_name IN ('deploy_migrate','worker_one','worker_two','metrics_agent','vacuum_agent');