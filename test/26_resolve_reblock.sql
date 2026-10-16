-- test/26_resolve_reblock.sql: a root that comes back while being resolved must alert again.
--
-- lock_tree_notify_resolved() decides what to report cleared and what to forget. Until 1.1.16 it
-- did so over the live tree in two statements - a SELECT that chose what to report and a separate
-- DELETE that chose what to forget - so a root that started blocking again between the two was
-- reported cleared and its alert row was kept. The next lock_tree_notify() then found the row,
-- treated the root as already alerted, and sent nothing for an incident still under way: a listener
-- told the incident was over while it was still going, and told no more.
--
-- The window is opened deterministically here, the way it was when the defect was found: a schema
-- that puts a pg_notify re-establishing the incident ahead of pg_catalog's on the search_path, so
-- the root is blocking again the moment the resolver's first statement hands its row to the loop.
-- With the fix there is no second read - one DELETE ... RETURNING decides and forgets at once - so
-- the trick changes nothing and the next lock_tree_notify() alerts again.
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

DROP SCHEMA IF EXISTS lock_tree_rr_shadow CASCADE;
DROP TABLE IF EXISTS lock_tree_rr_x;
CREATE TABLE lock_tree_rr_x (id int);
TRUNCATE lock_tree_alert;
CREATE TEMP TABLE rr_root AS SELECT null::int AS root_pid;

-- One root and two waiters: the shape the defect was found in.
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['rr_h', 'rr_w1', 'rr_w2']) AS n;
SELECT dblink_exec('rr_h', 'BEGIN');
SELECT dblink_exec('rr_h', 'SET application_name = ''rr_holder''');
SELECT dblink_exec('rr_h', 'LOCK TABLE lock_tree_rr_x IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('rr_w1', 'SET application_name = ''rr_w1''; SELECT count(*) FROM lock_tree_rr_x');
SELECT dblink_send_query('rr_w2', 'SET application_name = ''rr_w2''; SELECT count(*) FROM lock_tree_rr_x');
DO $wait$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
                 WHERE application_name IN ('rr_w1', 'rr_w2')
                   AND wait_event_type = 'Lock') = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;

SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS onset \gset
UPDATE rr_root SET root_pid = (SELECT root_pid FROM lock_tree_alert LIMIT 1);
\o
\set QUIET 0

SELECT plan(5);

SELECT is(:onset::int, 1, 'the incident alerts once');

-- End it: the holder releases, so the resolver has a root to clear.
\set QUIET 1
\o /dev/null
SELECT dblink_exec('rr_h', 'ROLLBACK');
DO $drain$
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE root_pid = (SELECT root_pid FROM rr_root));
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$drain$;

-- A waiter connected beforehand, and a pg_notify that re-establishes the incident before returning,
-- ahead of pg_catalog's. lock_tree_notify_resolved() calls pg_notify unqualified, so with this schema
-- on the search_path the root is blocking again while the resolver is still deciding.
SELECT dblink_connect('rr_w3', format('dbname=%s user=%s', current_database(), current_user));
CREATE SCHEMA lock_tree_rr_shadow;
CREATE FUNCTION lock_tree_rr_shadow.pg_notify(channel text, payload text)
RETURNS void
LANGUAGE plpgsql
AS $shadow$
BEGIN
  PERFORM public.dblink_exec('rr_h', 'BEGIN');
  PERFORM public.dblink_exec('rr_h', 'LOCK TABLE lock_tree_rr_x IN ACCESS EXCLUSIVE MODE');
  PERFORM public.dblink_send_query('rr_w3',
                                   'SET application_name = ''rr_w3''; SELECT count(*) FROM lock_tree_rr_x');
  -- A short wait, not a poll: pg_stat_activity is read once per statement, and the resolver has
  -- already read the tree in this one, so a poll here would keep seeing the old snapshot. The
  -- waiter blocks in milliseconds once the lock is taken; if it did not, the trap assertion in the
  -- test would fail rather than let the file pass without reproducing.
  PERFORM pg_catalog.pg_sleep(1);
  PERFORM pg_catalog.pg_notify(channel, payload);
END
$shadow$;

SET search_path = lock_tree_rr_shadow, pg_catalog;
SELECT public.lock_tree_notify_resolved(min_blocked => 1, min_depth => NULL, min_wait => NULL)
         AS resolved_race \gset
RESET search_path;

SELECT count(*) AS relocked FROM lock_tree WHERE root_pid = (SELECT root_pid FROM rr_root) \gset
SELECT count(*) AS rows_left FROM lock_tree_alert \gset
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS again \gset
\o
\set QUIET 0

SELECT ok(:relocked::int >= 1,
          'the trap was sprung: the root is blocking again after the resolver ran, which is what the '
          || 'defect needs to be visible, and is asserted so this file cannot pass by not reproducing');

SELECT is(:resolved_race::int, 1, 'the resolver reports the root cleared');

SELECT is(:rows_left::int, 0,
          'and forgets it. The root was gone when the resolver began and is blocking again by the '
          || 'time a second pass would read the tree, so a resolver that decided and forgot in two '
          || 'passes keeps the row here and hands back one');

SELECT is(:again::int, 1,
          'so the incident, still under way, alerts again rather than being swallowed as already '
          || 'alerted. A listener was told it was over and heard nothing more; that is the symptom');

\set QUIET 1
\o /dev/null
SELECT dblink_exec('rr_h', 'ROLLBACK');
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE application_name = 'rr_w3' AND pid <> pg_backend_pid();
DO $disc$
DECLARE c text;
BEGIN
  FOR c IN SELECT unnest(ARRAY['rr_h', 'rr_w1', 'rr_w2', 'rr_w3']) LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END
$disc$;
DROP SCHEMA IF EXISTS lock_tree_rr_shadow CASCADE;
DROP TABLE IF EXISTS lock_tree_rr_x;
TRUNCATE lock_tree_alert;
\o

SELECT * FROM finish();
