-- test/04_prepared.sql: pg_lock_tree v0.1: a prepared transaction as the root.
--
-- A prepared transaction keeps its locks until COMMIT/ROLLBACK PREPARED, has no backend, so
-- it is not in pg_stat_activity, and has no pid. pg_blocking_pids() reports it as 0. Without
-- special handling its waiters end up with a blocker that resolves to nothing.
--
-- Needs max_prepared_transactions > 0, which the pg-test images set in their CMD. Forgejo v16
-- ignores a `command:` override on a service container, so a CI job cannot turn it on; where
-- the setting is absent this file skips rather than fails, because the path is genuinely
-- untestable there and a hard error looks like a broken extension.
--
-- Superuser needed (dblink, PREPARE TRANSACTION).
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
\o
\unset QUIET

SELECT plan(9);

-- decide before touching anything: PREPARE TRANSACTION raises if the setting is 0
SELECT current_setting('max_prepared_transactions')::int > 0 AS have_ptx \gset

\if :have_ptx

\set QUIET 1
\o /dev/null
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
DECLARE
  blocked boolean := false;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT EXISTS (SELECT 1 FROM pg_stat_activity
                   WHERE wait_event_type = 'Lock'
                     AND query LIKE 'BEGIN; LOCK TABLE lock_tree_pt%') INTO blocked;
    EXIT WHEN blocked;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF NOT blocked THEN
    RAISE EXCEPTION 'the prepared-transaction waiter never blocked after 30s';
  END IF;
END
$wait$;

CREATE TEMP TABLE ptx AS
SELECT t.* FROM lock_tree t WHERE t.root_pid = 0;

CREATE TEMP TABLE ptx_roots AS
SELECT root_pid, suggested_action FROM lock_tree_roots() WHERE root_pid = 0;

CREATE TEMP TABLE ptx_cmds AS
SELECT command FROM lock_tree_command();
\o
\unset QUIET

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

-- 0.3: 0.2 gave this root the generic "try SELECT pg_cancel_backend(0)" advice, which returns
-- false and warns that PID 0 is not a PostgreSQL backend process. That is the one case where
-- the queue is genuinely stuck and the operator has no other signal, so handing back a command
-- that cannot work is worse than handing back none.
SELECT matches((SELECT suggested_action FROM ptx_roots),
               'ROLLBACK PREPARED',
               'the pid-0 root is told to ROLLBACK PREPARED, the only thing that clears it');

SELECT ok((SELECT position('pg_prepared_xacts' in suggested_action) > 0 FROM ptx_roots),
          'and is pointed at the catalog holding the gid, since lock_tree cannot see it');

SELECT ok((SELECT suggested_action NOT LIKE '%pg_cancel_backend(0)%'
                      AND suggested_action NOT LIKE '%pg_terminate_backend(0)%'
           FROM ptx_roots),
          'the pid-0 root is never told to cancel or terminate a backend that does not exist');

-- lock_tree_command() returns statements only. There is no statement for a prepared transaction,
-- because the one that would work needs a gid this extension cannot reach, so it returns nothing
-- rather than something that looks like a fix.
SELECT is((SELECT count(*) FROM ptx_cmds)::int, 0,
          'lock_tree_command() offers no statement for a prepared transaction');

-- release: ROLLBACK PREPARED frees the prepared transaction's locks, which lets I finish.
-- I's backend is then terminated rather than unwound: it has an unconsumed result from the
-- statement that was released mid-flight, and dblink_disconnect() waits on that.
\set QUIET 1
\o /dev/null
ROLLBACK PREPARED 'lock_tree_pt';

DO $drain$
DECLARE
  gone boolean := false;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT NOT EXISTS (SELECT 1 FROM lock_tree_pt_pids p
                       JOIN pg_stat_activity a ON a.pid = p.pid
                       WHERE a.state = 'idle in transaction'
                          OR (a.state = 'active' AND a.wait_event_type = 'Lock')) INTO gone;
    EXIT WHEN gone;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF NOT gone THEN
    RAISE WARNING 'the prepared-transaction sessions were still settling after 30s; the drop below is the real check';
  END IF;
END
$drain$;

SELECT pg_terminate_backend(pid) FROM lock_tree_pt_pids ORDER BY pid;

DO $gone$
DECLARE
  gone boolean := false;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT NOT EXISTS (SELECT 1 FROM lock_tree_pt_pids p
                       JOIN pg_stat_activity a ON a.pid = p.pid) INTO gone;
    EXIT WHEN gone;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF NOT gone THEN
    RAISE WARNING 'the prepared-transaction sessions were still visible after 30s; the drop below is the real check';
  END IF;
END
$gone$;

DROP TABLE lock_tree_pt_pids;
DROP TABLE lock_tree_pt;
\o
\unset QUIET

\else

SELECT skip('max_prepared_transactions is 0 on this server, so the prepared-transaction '
         || 'path cannot be exercised here', 9);

\endif

SELECT * FROM finish();