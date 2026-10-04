-- test/01_lock_tree.sql — pg_lock_tree v0.1 pgTAP suite
-- Builds a real blocking chain with dblink (needs superuser and the dblink contrib module):
--   A  holds ROW EXCLUSIVE on lock_tree_t, then sits idle in its transaction   (root)
--   B  wants ACCESS EXCLUSIVE           -> blocked by A                         (depth 1)
--   C  plain SELECT (ACCESS SHARE)      -> queued behind B's request            (depth 2)
--   D  plain SELECT (ACCESS SHARE)      -> queued behind B's request            (depth 2)
--   E  wants SHARE ROW EXCLUSIVE        -> blocked by A *and* queued behind B   (deepest: depth 2)
-- Runs in autocommit on purpose: an open transaction here would hide the table from the
-- dblink sessions and hold its own lock on it.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS dblink;
-- Installed as an extension locally; CI loads the SQL straight into public instead.
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

DROP TABLE IF EXISTS lock_tree_t;
CREATE TABLE lock_tree_t (id int);
DROP TABLE IF EXISTS lock_tree_pids;
CREATE TABLE lock_tree_pids (name text PRIMARY KEY, pid int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['a','b','c','d','e']) AS n;

INSERT INTO lock_tree_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['a','b','c','d','e']) AS n;

SELECT dblink_exec('a', 'BEGIN');
SELECT dblink_exec('a', 'LOCK TABLE lock_tree_t IN ROW EXCLUSIVE MODE');
SELECT dblink_send_query('b', 'BEGIN; LOCK TABLE lock_tree_t IN ACCESS EXCLUSIVE MODE; COMMIT');
SELECT pg_sleep(0.3);   -- B must be queued before the others arrive
SELECT dblink_send_query('e', 'BEGIN; LOCK TABLE lock_tree_t IN SHARE ROW EXCLUSIVE MODE; COMMIT');
SELECT pg_sleep(0.3);
SELECT dblink_send_query('c', 'SELECT count(*) FROM lock_tree_t');
SELECT dblink_send_query('d', 'SELECT count(*) FROM lock_tree_t');

DO $wait$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM lock_tree_pids WHERE name IN ('b','c','d','e'))
                 AND wait_event_type = 'Lock') = 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

CREATE TEMP TABLE snap AS
SELECT t.*, p.name
FROM lock_tree t JOIN lock_tree_pids p USING (pid);

CREATE TEMP TABLE roots AS
SELECT r.* FROM lock_tree_roots() r
WHERE r.root_pid = (SELECT pid FROM lock_tree_pids WHERE name = 'a');

CREATE TEMP TABLE txt AS
SELECT line FROM lock_tree_text() AS line;

\o
\unset QUIET
SELECT plan(19);

SELECT has_view('lock_tree', 'lock_tree view exists');
SELECT has_function('lock_tree_roots', 'lock_tree_roots() exists');
SELECT has_function('lock_tree_text', ARRAY['integer'], 'lock_tree_text(int) exists');

SELECT is((SELECT count(*) FROM snap)::int, 5, 'all five test sessions appear in the tree');

SELECT is((SELECT depth FROM snap WHERE name = 'a'), 0, 'A is a root (depth 0)');
SELECT is((SELECT state FROM snap WHERE name = 'a'), 'idle in transaction', 'A is idle in transaction');
SELECT is((SELECT depth FROM snap WHERE name = 'b'), 1, 'B sits directly under A');
SELECT is((SELECT depth FROM snap WHERE name = 'c'), 2, 'C sits under B');
SELECT is((SELECT depth FROM snap WHERE name = 'd'), 2, 'D sits under B');

SELECT is((SELECT path FROM snap WHERE name = 'c'),
          (SELECT ARRAY[(SELECT pid FROM lock_tree_pids WHERE name = 'a'),
                        (SELECT pid FROM lock_tree_pids WHERE name = 'b'),
                        (SELECT pid FROM lock_tree_pids WHERE name = 'c')]),
          'C''s path runs A -> B -> C');

SELECT is((SELECT root_pid FROM snap WHERE name = 'd'),
          (SELECT pid FROM lock_tree_pids WHERE name = 'a'),
          'D traces back to root A');

SELECT matches((SELECT waiting_for FROM snap WHERE name = 'b'),
               '^AccessExclusiveLock on lock_tree_t$',
               'B reports what it is waiting for, with the table name');

SELECT ok((SELECT wait_age FROM snap WHERE name = 'b') IS NOT NULL, 'B has a wait age');

SELECT is((SELECT blocked_sessions FROM roots), 4::bigint, 'root A blocks 4 sessions');

SELECT ok((SELECT blocked_by @> ARRAY[(SELECT pid FROM lock_tree_pids WHERE name = 'a'),
                                     (SELECT pid FROM lock_tree_pids WHERE name = 'b')]
           FROM snap WHERE name = 'e'),
          'E reports both of its blockers (A holds, B is queued ahead)');
SELECT is((SELECT depth FROM snap WHERE name = 'e'), 2,
          'a waiter with several blockers is placed on its deepest chain');
SELECT matches((SELECT suggested_action FROM roots),
               'pg_terminate_backend\(' || (SELECT pid FROM lock_tree_pids WHERE name = 'a') || '\)',
               'idle-in-transaction root gets a terminate suggestion naming its pid');

-- 0.2 changed the text layout: the root line is "pid  state  age  app  query" with no
-- bracket, and the age is compact ("0s", not "00:00:00"). Match the current format, and match
-- on the pid *and* the state so the assertion cannot pass on a waiter line.
SELECT ok((SELECT count(*) FROM txt
           WHERE line LIKE (SELECT pid FROM lock_tree_pids WHERE name = 'a')
                            || '  idle in transaction%') = 1,
          'text output has a root line for A');

-- release the chain and confirm the tree empties
\set QUIET 1
\o /dev/null
SELECT dblink_exec('a', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;
\o
\unset QUIET

SELECT is((SELECT count(*) FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_pids))::int, 0,
          'tree is empty once the root rolls back');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT dblink_disconnect(n) FROM unnest(ARRAY['a','b','c','d','e']) AS n;
DROP TABLE lock_tree_pids;
DROP TABLE lock_tree_t;
