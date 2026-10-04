-- s6_deadlock.sql: a wait-for cycle. Nobody is the blocker.
--
-- The case where the published recursive CTE cannot give a straight answer, and where a
-- tool that returns nothing is worse than useless: an operator staring at an empty result
-- while two sessions are provably stuck on each other.
--
-- The published form has no cycle guard at all, so its recursion runs until something else
-- stops it. We cap it at depth 20 here, which is the bolt-on every practitioner adds after
-- their first incident.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 6: two sessions deadlocked on each other ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s6_x;
DROP TABLE IF EXISTS s6_y;
DROP TABLE IF EXISTS s6_pids;
CREATE TABLE s6_x (id int);
CREATE TABLE s6_y (id int);
CREATE TABLE s6_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['d1','d2']) AS n;
INSERT INTO s6_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['d1','d2']) AS n;

-- Raise deadlock_timeout so the cycle is still there when we look. Left at the 1s default,
-- PostgreSQL resolves it before you can read anything.
SELECT dblink_exec('d1','SET deadlock_timeout = ''15s''');
SELECT dblink_exec('d2','SET deadlock_timeout = ''15s''');

-- Baseline for the deadlock counter, taken BEFORE the cycle exists.
--
-- Order matters here and getting it wrong is invisible: deadlock_timeout is 15s in this scenario
-- and the scenario runs for longer than that before it reaches the reporting section, so a sample
-- taken there has already seen the increment and a sample taken after it sees the same number. The
-- first version of this section took both samples at the reporting point and reported no movement
-- at all, which read as "the counter does not work" rather than as "the baseline was late".
TRUNCATE lock_tree_deadlock;
SELECT lock_tree_sample() AS baseline_rows;

-- D1 takes x then wants y; D2 takes y then wants x.
SELECT dblink_exec('d1','BEGIN');
SELECT dblink_exec('d2','BEGIN');
SELECT dblink_exec('d1','SET application_name = ''transfer_out''');
SELECT dblink_exec('d2','SET application_name = ''transfer_in''');
SELECT dblink_exec('d1','LOCK TABLE s6_x IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('d2','LOCK TABLE s6_y IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('d1','LOCK TABLE s6_y IN ACCESS EXCLUSIVE MODE');
SELECT pg_sleep(0.3);
SELECT dblink_send_query('d2','LOCK TABLE s6_x IN ACCESS EXCLUSIVE MODE');

DO $w$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s6_pids) AND wait_event_type='Lock') = 2;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

\echo ''
\echo '--- proof: each is blocked by the other. This is a cycle, not a queue. ---'
SELECT p.tag, a.application_name, a.state, pg_blocking_pids(a.pid) AS blocked_by_other
FROM s6_pids p JOIN pg_stat_activity a USING (pid) ORDER BY p.tag;

\echo ''
\echo '--- pg_lock_tree: both sessions appear, each its own root ---'
SELECT * FROM lock_tree_text();

-- The deadlock counter, sampled. Recorded here rather than in a test file because it only means
-- anything against a REAL deadlock, and this scenario already builds one that works every time.
-- A test file that provoked a deadlock inside the same psql session that was sampling it did not
-- work at all: the two interfered and the deadlock was never observed. Here the sample before is
-- taken with the cycle still holding, and the sample after is taken once the server has broken it.
\set QUIET 1
\o /dev/null
SELECT lock_tree_sample() AS during_rows \gset
\o
\unset QUIET

\echo ''
\echo '--- the deadlock counter, sampled before the cycle and while it holds ---'
\echo '--- two samples, no movement yet: the server has not broken it ---'
SELECT sampled_at, deadlocks, delta, counter_reset FROM lock_tree_deadlock ORDER BY sampled_at;

\echo ''
\echo '--- depth is 0 for both, and blocked_by shows the loop ---'
SELECT pid, root_pid, depth, blocked_by, waiting_for FROM lock_tree ORDER BY pid;

\echo ''
\echo '--- both are listed as roots to act on, with cancel suggestions ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- pg_lock_tree roots: no single biggest win, so both are offered ---'
SELECT root_pid, application_name, state, blocked_sessions, max_depth
FROM lock_tree_roots() ORDER BY root_pid;

\echo ''
\echo '--- standard query on a cycle: recursion has no exit, so it is capped at depth 20 ---'
\i 01_standard_query.sql

\echo ''
\echo '--- what that cost. Same incident, same data, two answers. ---'
WITH std AS (SELECT count(*) AS rows FROM std_result),
     plt AS (SELECT count(*) AS rows FROM lock_tree)
SELECT std.rows   AS standard_query_rows,
       plt.rows   AS pg_lock_tree_rows,
       round(100.0 * std.rows / nullif(plt.rows,0)) AS ratio
FROM std, plt;

\echo ''
\echo '--- the deadlock counter, sampled before the cycle and while it holds ---'
\echo '--- two samples, no movement yet, because the server has not decided to break it ---'
SELECT sampled_at, deadlocks, delta, counter_reset FROM lock_tree_deadlock ORDER BY sampled_at;
\echo ''
\echo '--- the counter moves when the server breaks the cycle, which is deadlock_timeout after'
\echo '--- the wait began. This scenario raises that to 15s so the cycle survives long enough to'
\echo '--- be looked at, so the increment lands after this scenario has moved on.'
\echo '--- scripts/check-deadlock.sh observes the move, in a separate process, at the default'
\echo '--- timeout. Run that if you want to see the counter actually change.'
SELECT (SELECT deadlocks FROM lock_tree_deadlock ORDER BY sampled_at DESC LIMIT 1) AS sampled,
       (SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()) AS live;

\echo ''
\echo '   Both report the same two sessions. The difference is that the published form walks'
\echo '   the cycle round and round until the depth cap stops it, so the same pair of pids'
\echo '   appears at depths 1..20 in both directions, 40 rows describing a 2-session'
\echo '   incident. There is no row that says "these two are each other''s blocker", because'
\echo '   that is not a shape the recursion can express.'

\set QUIET 1
\o /dev/null
CREATE TEMP TABLE s6_kill AS SELECT pid FROM s6_pids;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s6_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s6_kill));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['d1','d2'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s6_pids; DROP TABLE s6_x; DROP TABLE s6_y;
\o
\unset QUIET
SELECT count(*) AS s6_sessions_left FROM pg_stat_activity
WHERE application_name IN ('transfer_out','transfer_in');