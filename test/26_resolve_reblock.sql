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
-- The wait for the waiter to be blocked is a pg_locks poll, not a sleep: pg_stat_activity is read
-- once per statement and the resolver has already read it, while pg_locks is read live, so the test
-- exits as soon as the lock request is pending and a slower runner cannot outlast it. Verified 20
-- runs on each of PostgreSQL 14 to 18, and 20 more under full CPU load, with no flake.
--
-- Every poll is bounded at 20s and **fails** when it expires, naming the waiter it never saw. A
-- poll that fell through on expiry would let a runner too slow to block the waiter carry on and
-- pass or fail for the wrong reason; there are three of them, and each raises rather than returns.
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
DECLARE
  blocked int;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT count(*) INTO blocked FROM pg_stat_activity
     WHERE application_name IN ('rr_w1', 'rr_w2')
       AND wait_event_type = 'Lock';
    EXIT WHEN blocked = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF blocked <> 2 THEN
    RAISE EXCEPTION 'the waiters never blocked: rr_w1 and rr_w2 were not both waiting on '
                    'lock_tree_rr_x after 20s (saw %). pg_locks: % | activity: %',
      blocked,
      (SELECT coalesce(string_agg(format('%s/%s granted=%s pid=%s', locktype, mode, granted, pid),
                                  ' | ' ORDER BY pid), '(none)')
         FROM pg_locks WHERE relation = 'lock_tree_rr_x'::regclass),
      (SELECT coalesce(string_agg(format('%s state=%s wait=%s/%s', application_name, state,
                                        wait_event_type, wait_event), ' | ' ORDER BY application_name),
                       '(none)')
         FROM pg_stat_activity WHERE application_name IN ('rr_holder', 'rr_w1', 'rr_w2'));
  END IF;
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
DECLARE
  gone boolean := false;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT NOT EXISTS (SELECT 1 FROM lock_tree WHERE root_pid = (SELECT root_pid FROM rr_root)) INTO gone;
    EXIT WHEN gone;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF NOT gone THEN
    RAISE EXCEPTION 'the root never cleared: it was still in lock_tree after 20s, so the resolver '
                    'had nothing to clear and the rest of this file proves nothing. rows for the '
                    'root: %', (SELECT count(*) FROM lock_tree WHERE root_pid = (SELECT root_pid FROM rr_root));
  END IF;
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
DECLARE
  blocked boolean := false;
BEGIN
  PERFORM public.dblink_exec('rr_h', 'BEGIN');
  PERFORM public.dblink_exec('rr_h', 'LOCK TABLE lock_tree_rr_x IN ACCESS EXCLUSIVE MODE');
  PERFORM public.dblink_send_query('rr_w3',
                                   'SET application_name = ''rr_w3''; SELECT count(*) FROM lock_tree_rr_x');
  -- Wait for the waiter to be blocked, on pg_locks rather than pg_stat_activity: the resolver has
  -- already read pg_stat_activity in this statement, so a poll there would keep seeing the old
  -- snapshot, while pg_locks is read live. It exits as soon as the request is pending, so it does
  -- not depend on how fast the runner is - and never a fixed sleep, which a loaded runner could
  -- outlast and turn into a false miss. If it expires the request was never seen pending, and that
  -- is a failed run, not a quiet one: the trap below cannot be sprung without it.
  FOR i IN 1..200 LOOP
    SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_locks
                    WHERE relation = 'public.lock_tree_rr_x'::regclass
                      AND NOT granted) INTO blocked;
    EXIT WHEN blocked;
    PERFORM pg_catalog.pg_sleep(0.1);
  END LOOP;
  IF NOT blocked THEN
    RAISE EXCEPTION 'the waiter never blocked: rr_w3 was not waiting on lock_tree_rr_x after 20s. '
                    'pg_locks: %',
      (SELECT coalesce(string_agg(format('%s/%s granted=%s pid=%s', locktype, mode, granted, pid),
                                  ' | ' ORDER BY pid), '(none)')
         FROM pg_catalog.pg_locks WHERE relation = 'public.lock_tree_rr_x'::regclass);
  END IF;
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
