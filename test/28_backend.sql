-- test/28_backend.sql: lock_tree_backend(pid), one backend by pid.
--
-- The tree is for an incident; an alert or a paste usually carries one pid. This checks the facts
-- an operator needs without reading the whole tree: backend type, the lock waited for, the immediate
-- blocker and the locks the backend holds.
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

DROP TABLE IF EXISTS lt_bk_t;
CREATE TABLE lt_bk_t (id int);
INSERT INTO lt_bk_t VALUES (1);

SELECT dblink_connect('lt_bk_blk',
                      format('dbname=%s user=%s application_name=lt_bk_blk',
                             current_database(), current_user));
SELECT dblink_connect('lt_bk_wait',
                      format('dbname=%s user=%s application_name=lt_bk_wait',
                             current_database(), current_user));
SELECT pid AS blk_pid FROM dblink('lt_bk_blk', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT pid AS wait_pid FROM dblink('lt_bk_wait', 'SELECT pg_backend_pid()') AS t(pid int) \gset

SELECT dblink_exec('lt_bk_blk', 'BEGIN');
SELECT dblink_exec('lt_bk_blk', 'LOCK TABLE lt_bk_t IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('lt_bk_wait', 'SELECT count(*) FROM lt_bk_t');
SELECT set_config('lt_bk.wait_pid', :'wait_pid', false);

DO $wait$
DECLARE i int;
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT cardinality(blocked_by) FROM lock_tree_backend(current_setting('lt_bk.wait_pid')::int)) > 0;
    PERFORM pg_sleep(0.05);
  END LOOP;
END
$wait$;
\o
\unset QUIET

SELECT plan(8);

SELECT has_function('lock_tree_backend', ARRAY['integer'],
                    'lock_tree_backend(integer) exists');
SELECT is((SELECT count(*)::int FROM lock_tree_backend(pg_backend_pid())), 1,
          'one pid returns exactly one row');
SELECT is((SELECT backend_type FROM lock_tree_backend(pg_backend_pid())), 'client backend',
          'the row carries the backend type');
SELECT is((SELECT blocked_by FROM lock_tree_backend(pg_backend_pid())), '{}'::int[],
          'a backend that is not waiting has no blockers');
SELECT ok((SELECT holds @> ARRAY['AccessExclusiveLock on lt_bk_t']
             FROM lock_tree_backend(:blk_pid)),
          'the blocker reports the lock it holds, by mode and object');
SELECT is((SELECT blocked_by FROM lock_tree_backend(:wait_pid)), ARRAY[:blk_pid]::int[],
          'the waiter names its immediate blocker');
SELECT ok((SELECT waiting_for IS NOT NULL AND wait_age IS NOT NULL
             FROM lock_tree_backend(:wait_pid)),
          'the waiter reports what it waits for and for how long');
SELECT is((SELECT count(*)::int FROM lock_tree_backend(0)), 0,
          'a pid that is not a backend returns no row, not a fabricated one');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT dblink_exec('lt_bk_blk', 'ROLLBACK');
SELECT * FROM dblink_get_result('lt_bk_wait') AS t(c bigint);
SELECT * FROM dblink_get_result('lt_bk_wait') AS t(c bigint);
SELECT dblink_disconnect(n) FROM unnest(ARRAY['lt_bk_blk','lt_bk_wait']) AS n;
DROP TABLE lt_bk_t;
\o
\unset QUIET
