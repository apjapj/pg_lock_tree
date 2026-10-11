-- test/25_first_waiting_for.sql: lock_tree_wide().first_waiting_for is the longest waiter's lock.
--
-- The column promises "first", and until 1.1.16 it was min(waiting_for): the alphabetically least
-- lock description in the tree. That agrees with "first" only when every waiter wants the same lock,
-- which is the usual case and the only one test/08 builds. Here one root holds two tables and its two
-- waiters queue on different ones, the older waiter on the table whose description sorts LAST, so
-- min() and "the longest waiter" give different answers and the test can tell them apart.
--
-- wait_age is truncated to whole seconds, so the two waits are started two seconds apart and the
-- order between them is never a tie.
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

DROP TABLE IF EXISTS lock_tree_fw_zz;
DROP TABLE IF EXISTS lock_tree_fw_aa;
CREATE TABLE lock_tree_fw_zz (id int);
CREATE TABLE lock_tree_fw_aa (id int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['fw_root', 'fw_old', 'fw_new']) AS n;
SELECT dblink_exec('fw_root', 'BEGIN');
SELECT dblink_exec('fw_root', 'LOCK TABLE lock_tree_fw_zz IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('fw_root', 'LOCK TABLE lock_tree_fw_aa IN ACCESS EXCLUSIVE MODE');

-- The older waiter first, on the table that sorts last.
SELECT dblink_send_query('fw_old', 'SELECT count(*) FROM lock_tree_fw_zz');
SELECT pg_sleep(2);
SELECT dblink_send_query('fw_new', 'SELECT count(*) FROM lock_tree_fw_aa');
DO $wait$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks WHERE NOT granted
                AND relation IN ('lock_tree_fw_zz'::regclass, 'lock_tree_fw_aa'::regclass)) = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

CREATE TEMP TABLE fw AS
SELECT w.* FROM lock_tree_wide() w
 WHERE w.root_pid = (SELECT p FROM dblink('fw_root', 'SELECT pg_backend_pid()') AS t(p int));
\o
\unset QUIET

SELECT plan(3);

SELECT is((SELECT blocked_sessions FROM fw), 2::bigint,
          'one root, two waiters queued on two different tables');

SELECT is((SELECT first_waiting_for FROM fw), 'AccessShareLock on lock_tree_fw_zz',
          'first_waiting_for is what the LONGEST waiter wants, which here sorts last, '
          || 'so min() would have named the other table');

SELECT isnt((SELECT first_waiting_for FROM fw), 'AccessShareLock on lock_tree_fw_aa',
            'and not the alphabetically least description, which is what 1.1.15 and earlier reported');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
DO $b$ DECLARE conn text; BEGIN
  FOR conn IN SELECT unnest(ARRAY['fw_old', 'fw_new', 'fw_root']) LOOP
    BEGIN PERFORM dblink_disconnect(conn); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_fw_zz;
DROP TABLE lock_tree_fw_aa;
\o
\unset QUIET
