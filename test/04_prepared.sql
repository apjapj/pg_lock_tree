-- test/04_prepared.sql — pg_lock_tree v0.1: a prepared transaction as the root.
--
-- A prepared transaction keeps its locks until COMMIT/ROLLBACK PREPARED, has no backend, so
-- it is not in pg_stat_activity, and has no pid. pg_blocking_pids() reports it as 0. Without
-- special handling its waiters end up with a blocker that resolves to nothing.
--
-- Needs max_prepared_transactions > 0, which the pg-dev-infra compose file sets on every
-- service. Superuser needed (dblink, PREPARE TRANSACTION).
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

DROP TABLE IF EXISTS lock_tree_pt;
DROP TABLE IF EXISTS lock_tree_pt_pids;
CREATE TABLE lock_tree_pt (id int);
CREATE TABLE lock_tree_pt_pids (name text PRIMARY KEY, pid int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['h','i']) AS n;

-- a regular table, not a temp one: the dblink backends have to see it
INSERT INTO lock_tree_pt_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['h','i']) AS n;

-- H locks the table and prepares; its locks outlive the session
SELECT dblink_exec('h', 'BEGIN');
SELECT dblink_exec('h', 'LOCK TABLE lock_tree_pt IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('h', 'PREPARE TRANSACTION ''lock_tree_pt''');

SELECT dblink_send_query('i', 'BEGIN; LOCK TABLE lock_tree_pt IN SHARE MODE; COMMIT');

DO $wait$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN EXISTS (SELECT 1 FROM pg_stat_activity
                      WHERE wait_event_type = 'Lock'
                        AND query LIKE 'BEGIN; LOCK TABLE lock_tree_pt%');
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

CREATE TEMP TABLE ptx AS
SELECT t.* FROM lock_tree t WHERE t.root_pid = 0;
\o
\unset QUIET

SELECT plan(5);

SELECT is((SELECT count(*) FROM ptx)::int, 2,
          'the waiter and its prepared-transaction blocker both appear');

SELECT is((SELECT root_pid FROM ptx WHERE pid = 0), 0,
          'the prepared transaction is its own root, at pid 0');

SELECT is((SELECT state FROM ptx WHERE pid = 0),
          'prepared transaction (see pg_prepared_xacts)',
          'the pid-0 root is labelled as a prepared transaction');

SELECT is((SELECT depth FROM ptx WHERE pid <> 0), 1,
          'the waiter sits directly under the prepared transaction');

SELECT is((SELECT count(*) FROM lock_tree_roots() WHERE root_pid = 0), 1::bigint,
          'lock_tree_roots() reports the prepared transaction as a root to act on');

-- release: ROLLBACK PREPARED frees the prepared transaction's locks, which lets I finish.
-- I's backend is then terminated rather than unwound: it has an unconsumed result from the
-- statement that was released mid-flight, and dblink_disconnect() waits on that.
\set QUIET 1
\o /dev/null
ROLLBACK PREPARED 'lock_tree_pt';

DO $drain$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree_pt_pids p
                          JOIN pg_stat_activity a ON a.pid = p.pid
                          WHERE a.state = 'idle in transaction'
                             OR (a.state = 'active' AND a.wait_event_type = 'Lock'));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;

SELECT pg_terminate_backend(pid) FROM lock_tree_pt_pids ORDER BY pid;

DO $gone$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree_pt_pids p
                          JOIN pg_stat_activity a ON a.pid = p.pid);
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$gone$;

DROP TABLE lock_tree_pt_pids;
DROP TABLE lock_tree_pt;
\o
\unset QUIET

SELECT * FROM finish();