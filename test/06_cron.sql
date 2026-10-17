-- test/06_cron.sql: pg_lock_tree sampled on a schedule by pg_cron.
--
-- Feasibility check for scheduled history, which is the one thing pg_lock_tree cannot show an
-- operator at the moment they need it: an incident that has already cleared. Everything else in
-- the suite reports the present. This proves a background job can read lock_tree, land the
-- result somewhere durable, and have it outlive the incident that produced it.
--
-- Deliberately NOT lock_tree_history, and this file does not pretend to be it. There is no
-- retention policy, no threshold alerting and no NOTIFY here. What it establishes is narrower and
-- is the part that could actually have failed: that pg_cron can load, that a job it runs can
-- query the view as a different session, and that the result is retrievable afterwards.
--
-- The incident mirrors test/01_lock_tree.sql, three sessions deep:
--   X  holds ACCESS EXCLUSIVE on lock_tree_ct, then sits idle in its transaction  (root, depth 0)
--   Y  wants ACCESS EXCLUSIVE                        -> blocked by X                 (depth 1)
--   Z  plain SELECT                                  -> queued behind Y               (depth 2)
--
-- pg_cron is a dependency of the TEST HARNESS, never of the extension: pg_lock_tree itself needs
-- no shared_preload_libraries. Where pg_cron is absent or not preloaded this file skips rather
-- than fails, for the same reason 04_prepared.sql does. A hard error here would look like a
-- broken extension when it is only a missing optional module.
--
-- Needs superuser (dblink, and cron.schedule, which only a superuser may create by default).
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

-- Two conditions, not one, and they are in this order for a reason.
--
-- The preloaded check has to come first and gate the CREATE. pg_cron is a loadable module with a
-- SQL extension in front of it: `shared_preload_libraries = pg_cron` alone does not give you
-- cron.schedule(), and `CREATE EXTENSION pg_cron` on a server that never preloaded it appears to
-- succeed and then leaves you with no working scheduler. So test the preload, and only then create.
--
-- This ordering matters more than it looks. An earlier version of this file checked for the
-- cron.schedule() function first and skipped whenever it was absent, which meant it skipped on
-- any database where nobody had run CREATE EXTENSION pg_cron yet, including a server where
-- pg_cron was preloaded and working perfectly. It reported "not available" for a capability that
-- was in fact there. A test that silently skips on a working setup is worse than no test.
SELECT (current_setting('shared_preload_libraries') LIKE '%pg_cron%') AS cron_preloaded \gset

\if :cron_preloaded
\set QUIET 1
\o /dev/null
CREATE EXTENSION IF NOT EXISTS pg_cron;
\o
\unset QUIET
\endif

-- Computed entirely server-side, with no \gset interpolation of a boolean. Interpolating one
-- yields the bare literal t or f, which psql passes on as an unquoted identifier: "column t does
-- not exist". That is a confusing way to learn that booleans do not interpolate.
SELECT (current_setting('shared_preload_libraries') LIKE '%pg_cron%'
        AND to_regprocedure('cron.schedule(text,text,text)') IS NOT NULL) AS have_cron \gset

\if :have_cron

\set QUIET 1
\o /dev/null
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS lock_tree_ct;
DROP TABLE IF EXISTS lock_tree_ct_pids;
DROP TABLE IF EXISTS lock_tree_cron_snap;
CREATE TABLE lock_tree_ct (id int);
CREATE TABLE lock_tree_ct_pids (name text PRIMARY KEY, pid int);
-- What a history table has to look like. No primary key and no ON CONFLICT: pg_cron re-runs the
-- job on its own schedule, so the job must be an unconditional append.
CREATE TABLE lock_tree_cron_snap (
  sampled_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  root_pid    int,
  depth       int,
  pid         int,
  state       text,
  waiting_for text
);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['x','y','z']) AS n;

INSERT INTO lock_tree_ct_pids
SELECT n, (SELECT p FROM dblink(n, 'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['x','y','z']) AS n;

SELECT dblink_exec('x', 'BEGIN');
SELECT dblink_exec('x', 'LOCK TABLE lock_tree_ct IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('y', 'BEGIN; LOCK TABLE lock_tree_ct IN ACCESS EXCLUSIVE MODE; COMMIT');
SELECT pg_sleep(0.3);   -- Y must be queued before Z arrives
SELECT dblink_send_query('z', 'SELECT count(*) FROM lock_tree_ct');

DO $wait$
DECLARE
  blocked int;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT count(*) INTO blocked FROM pg_stat_activity
     WHERE pid IN (SELECT pid FROM lock_tree_ct_pids WHERE name IN ('y','z'))
       AND wait_event_type = 'Lock';
    EXIT WHEN blocked = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF blocked <> 2 THEN
    RAISE EXCEPTION 'the waiters never blocked: % of 2 were waiting on lock_tree_ct after 30s', blocked;
  END IF;
END
$wait$;

-- The job body. One statement, an unconditional append, no parameters: pg_cron hands the string
-- straight to a new libpq session that has never seen this file.
SELECT cron.schedule('lock_tree_cron_test', '10 seconds', $$
  INSERT INTO lock_tree_cron_snap (root_pid, depth, pid, state, waiting_for)
  SELECT root_pid, depth, pid, state, waiting_for FROM lock_tree
$$);

-- Wait for a sample. The schedule is 10 seconds, so the first run is at most that far away, but
-- allow more in one case: the cron launcher wakes once a second and this is a loaded CI box.
DO $poll$
DECLARE
  seen boolean := false;
BEGIN
  FOR i IN 1..120 LOOP
    SELECT EXISTS (SELECT 1 FROM lock_tree_cron_snap) INTO seen;
    EXIT WHEN seen;
    PERFORM pg_sleep(0.5);
  END LOOP;
  IF NOT seen THEN
    RAISE EXCEPTION 'the cron job never wrote a sample: lock_tree_cron_snap stayed empty for 60s';
  END IF;
END
$poll$;

-- Freeze the sample for the assertions, because the job keeps appending while they run and the
-- row count would otherwise change underneath them.
CREATE TEMP TABLE sample AS
SELECT DISTINCT ON (pid) sampled_at, root_pid, depth, pid, state, waiting_for
FROM lock_tree_cron_snap ORDER BY pid, sampled_at;

CREATE TEMP TABLE jobruns AS
SELECT status, return_message FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'lock_tree_cron_test');

SELECT cron.unschedule('lock_tree_cron_test');
\o
\unset QUIET

SELECT is((SELECT count(*) FROM jobruns)::int, 1, 'pg_cron ran the job exactly once in the poll window');
SELECT is((SELECT status FROM jobruns), 'succeeded', 'the job succeeded rather than erroring');

SELECT is((SELECT count(*) FROM sample)::int, 3,
          'the sampled snapshot holds all three sessions of the live chain');

SELECT is((SELECT depth FROM sample WHERE pid = (SELECT pid FROM lock_tree_ct_pids WHERE name = 'x')),
          0, 'the sampled root is at depth 0, as it is live');
SELECT is((SELECT state FROM sample WHERE pid = (SELECT pid FROM lock_tree_ct_pids WHERE name = 'x')),
          'idle in transaction', 'the sample records the root state, not just its pid');
SELECT is((SELECT depth FROM sample WHERE pid = (SELECT pid FROM lock_tree_ct_pids WHERE name = 'z')),
          2, 'the sampled chain keeps its shape: the reader queued behind the writer is depth 2');

SELECT is((SELECT count(*) FROM sample WHERE root_pid
             = (SELECT pid FROM lock_tree_ct_pids WHERE name = 'x'))::int, 3,
          'every sampled row traces back to the one root, which is what makes it a tree');

-- The point of sampling at all: the copy survives the incident.
\set QUIET 1
\o /dev/null
SELECT dblink_exec('x', 'ROLLBACK');
DO $drain$
DECLARE
  gone boolean := false;
BEGIN
  FOR i IN 1..300 LOOP
    SELECT NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_ct_pids)) INTO gone;
    EXIT WHEN gone;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF NOT gone THEN
    RAISE EXCEPTION 'the chain never cleared: lock_tree still held it after 30s';
  END IF;
END
$drain$;
\o
\unset QUIET

SELECT is((SELECT count(*) FROM lock_tree WHERE pid IN (SELECT pid FROM lock_tree_ct_pids))::int, 0,
          'the live tree is empty again');

SELECT is((SELECT count(*) FROM lock_tree_cron_snap)::int, 3,
          'but the sampled rows are still there, which is the entire reason to sample');

\set QUIET 1
\o /dev/null
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM lock_tree_ct_pids LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['x','y','z'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE lock_tree_cron_snap;
DROP TABLE lock_tree_ct_pids;
DROP TABLE lock_tree_ct;
\o
\unset QUIET

\else

SELECT skip('pg_cron is not in shared_preload_libraries on this server, so the '
         || 'scheduled-sampling path cannot be exercised here', 9);

\endif

SELECT * FROM finish();