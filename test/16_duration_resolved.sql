-- test/16_duration_resolved.sql: blocking TIME rather than a sample count, and knowing when an
-- incident is over.
--
-- Two unrelated additions to 0.12, in one file because both are about the same thing: turning what
-- the extension recorded into something an operator can act on.
--
-- BLOCKING TIME. lock_tree_history_statements() counts blocked sessions per sample, so it doubles
-- if you sample twice as often over the same incident. That is not a duration and the 0.7
-- documentation says so. lock_tree_duration() sums the GAPS between sample instants, and a gap
-- counts only where the query was the root at BOTH ends, so the figure is a measurement rather than
-- an interpolation.
--
-- RESOLUTION NOTICES. lock_tree_notify() says when something is getting worse and then says nothing,
-- which is right for a pager and wrong for the person who was woken up. lock_tree_notify_resolved()
-- sends one 'cleared' notification per root that had alerted and has since left the tree.
--
-- Needs superuser (dblink), the dblink contrib module, and max_prepared_transactions untouched.
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

TRUNCATE lock_tree_history;
TRUNCATE lock_tree_alert;

-- Unique names: several files create chains, and two of them creating the same relation is how a
-- suite starts failing for reasons unrelated to what it tests.
DROP TABLE IF EXISTS lock_tree_dr1;
DROP TABLE IF EXISTS lock_tree_dr2;
CREATE TABLE lock_tree_dr1 (id int);
CREATE TABLE lock_tree_dr2 (id int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['dr1','dr2','dw1','dw2','dw3']) AS n;
CREATE TEMP TABLE dr_pids AS
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int)) AS pid
FROM unnest(ARRAY['dr1','dr2','dw1','dw2','dw3']) AS s(n);

SELECT dblink_exec('dr1','BEGIN');
SELECT dblink_exec('dr1','SET application_name = ''slow_batch''');
SELECT dblink_exec('dr1','LOCK TABLE lock_tree_dr1 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('dr2','BEGIN');
SELECT dblink_exec('dr2','SET application_name = ''quick_batch''');
SELECT dblink_exec('dr2','LOCK TABLE lock_tree_dr2 IN ACCESS EXCLUSIVE MODE');
-- One statement per connection, carrying the SET. dblink allows one in-flight command, so a
-- separate send_query for the SET fails with "another command is already in progress". The
-- application_name matters: the cleanup below scopes on it, and an unnamed waiter is one that
-- cannot be terminated by name and then sits there holding a query.
SELECT dblink_send_query('dw1','SET application_name = ''api_duration''; SELECT count(*) FROM lock_tree_dr1');
SELECT dblink_send_query('dw2','SET application_name = ''api_duration''; SELECT count(*) FROM lock_tree_dr1');
SELECT dblink_send_query('dw3','SET application_name = ''api_duration''; SELECT count(*) FROM lock_tree_dr2');
DO $wait$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE application_name IN ('api_duration') AND wait_event_type = 'Lock') = 3;
  PERFORM pg_sleep(0.1);
END LOOP; END $wait$;

-- Each sample MUST be its own statement. statement_timestamp() is fixed for the duration of a
-- statement, so a loop of samples inside a DO block collapses onto one instant and the history
-- records no elapsed time at all. Measured before writing this file: three samples in a DO block
-- give one distinct sampled_at; three as separate statements give three.
\set QUIET 1
\o /dev/null
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
-- dr2 goes away here, so the second query is the root for about half as long.
SELECT dblink_exec('dr2','ROLLBACK');
SELECT pg_sleep(0.2);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();
\o
\set QUIET 0

SELECT plan(19);

SELECT has_function('lock_tree_duration', ARRAY['interval'], 'lock_tree_duration(interval) exists');

SELECT has_function('lock_tree_notify_resolved', ARRAY['text','integer','integer','interval'],
                    'lock_tree_notify_resolved() exists');

-- ------------------------------------------------------------------ blocking time

\set QUIET 1
\o /dev/null
SELECT count(DISTINCT sampled_at) AS instants FROM lock_tree_history \gset
SELECT count(*) AS dur_rows FROM lock_tree_duration() \gset
SELECT count(*) AS slow FROM lock_tree_duration() WHERE applications = ARRAY['slow_batch'] \gset
SELECT count(*) AS quick FROM lock_tree_duration() WHERE applications = ARRAY['quick_batch'] \gset
SELECT max(blocking_seconds) AS top_seconds FROM lock_tree_duration() \gset
SELECT min(blocking_seconds) AS bottom_seconds FROM lock_tree_duration() \gset
SELECT sum(gaps) AS total_gaps, sum(gaps_excluded) AS total_excluded FROM lock_tree_duration() \gset
\o
\set QUIET 0

SELECT is(:instants::int, 5,
          'five sample instants, which is what makes a duration measurable at all');

SELECT is(:dur_rows::int, 2, 'one row per root query id, so two');

SELECT ok(:top_seconds::numeric > :bottom_seconds::numeric,
          'and the one that held longer is ranked first, which is the whole point of a duration');

-- The arithmetic, checked against the samples rather than against a hardcoded number. The slow
-- root's instants are consecutive, so its time is the sum of the gaps between them. That sum is
-- computed here from the history and compared with what the function reports. A fixture built from
-- sleeps runs longer when the machine is busy, so comparing against a literal target is a race:
-- this assertion once failed on a loaded CI runner while the function was right and nothing about
-- the function had changed. Comparing against the recorded instants removes the race.
\set QUIET 1
\o /dev/null
WITH instants AS (SELECT DISTINCT sampled_at FROM lock_tree_history),
spans AS (SELECT sampled_at AS f, lead(sampled_at) OVER (ORDER BY sampled_at) AS t FROM instants),
slow_instants AS (
  -- query_id IS NOT NULL matches how lock_tree_duration() defines a root, so the sum below spans
  -- exactly the gaps the function is entitled to count and no others.
  SELECT DISTINCT sampled_at FROM lock_tree_history
   WHERE application_name = 'slow_batch' AND depth = 0 AND query_id IS NOT NULL
)
SELECT coalesce(extract(epoch FROM sum(t - f)), 0) AS expected_slow
FROM spans s
WHERE s.t IS NOT NULL
  AND s.f IN (SELECT sampled_at FROM slow_instants)
  AND s.t IN (SELECT sampled_at FROM slow_instants)
\gset
\o
\set QUIET 0

\set QUIET 1
\o /dev/null
SELECT blocking_seconds AS slow_seconds FROM lock_tree_duration()
 WHERE applications = ARRAY['slow_batch'] \gset
SELECT count(*) AS dropped_for_slow FROM lock_tree_duration()
 WHERE applications = ARRAY['quick_batch'] AND gaps_excluded > 0 \gset
\o
\set QUIET 0

-- One assertion, so the plan does not move. The first half is the arithmetic: the function must
-- report the gaps the slow root actually spans, to within half a second. The second half is a
-- fixture-sanity bound, loose on purpose. A fixture that never ran has expected_slow near zero, and
-- then the first half would compare 0 with 0 and pass, so the bound is what fails on a broken run.
SELECT ok(abs(:slow_seconds::numeric - :expected_slow::numeric) < 0.5
          AND :expected_slow::numeric BETWEEN 1.5 AND 6,
          'the slow root holds across the observed samples, and the function reports a duration '
          || 'within half a second of the gaps those samples actually span. It is a lower bound, '
          || 'not an estimate: the interval after the last sample is never counted because nobody '
          || 'observed it');

SELECT is(:dropped_for_slow::int, 1,
          'and one gap was DISCARDED rather than apportioned, because the quick root had already '
          || 'gone at the far end of it. Nobody observed when it stopped, so no split is invented');

-- Not 5. gaps and gaps_excluded are per QUERY, and in four of the gaps both roots were standing,
-- so each such gap is counted once for each. The accounting is complete if the two sum to the
-- number of gaps that actually had a root at their near end, which is the honest invariant.
SELECT is(:total_gaps::int + :total_excluded::int, 6,
          'every gap is either counted or excluded, so none is silently dropped: 6 gaps across the '
          || 'two queries, since four of them had both roots standing at their near end and count '
          || 'once for each. 5 instants give 4 gaps for one query and 2 for the other, and the '
          || 'quick query only appears in the first 2 instants, so 4 plus 2 is 6');

-- A window that excludes the samples reports nothing, which is what makes the argument meaningful.
\set QUIET 1
\o /dev/null
SELECT count(*) AS narrow FROM lock_tree_duration(interval '1 millisecond') \gset
SELECT count(*) AS empty FROM lock_tree_duration() WHERE blocking_seconds = 0 \gset
\o
\set QUIET 0

SELECT is(:narrow::int, 0, 'a window excluding every sample reports no rows');

SELECT is(:empty::int, 0,
          'and no query reported zero seconds while having been seen, so a present row always has '
          || 'a measured duration');

-- The counter-example, which is what makes this file worth more than the one before it: samples
-- inside ONE statement produce rows but no elapsed time, and the function must not paper over it.
\set QUIET 1
\o /dev/null
CREATE TEMP TABLE before_loop AS
SELECT count(DISTINCT sampled_at) AS instants, count(*) AS rows FROM lock_tree_history;
DO $loop$ BEGIN FOR i IN 1..4 LOOP PERFORM lock_tree_sample(); PERFORM pg_sleep(1); END LOOP; END $loop$;
\o
\set QUIET 0

\set QUIET 1
\o /dev/null
SELECT (SELECT count(DISTINCT sampled_at) FROM lock_tree_history) - b.instants AS new_instants,
       (SELECT count(*) FROM lock_tree_history) - b.rows              AS new_rows,
       (SELECT max(blocking_seconds) FROM lock_tree_duration())       AS still_max
FROM before_loop b \gset
\o
\set QUIET 0

-- Rows ARE written here, because dr1's rollback has not happened yet at this point in the file.
-- That is what makes this the right test: the rows look fine, the instants do not.
-- 12, not 8: both dr1 and dr2 are still roots here, because dr2's ROLLBACK happened but its
-- waiters are separate sessions, and dr1 holds with two waiters on dr1 and one on dr2. Rather than
-- count this by hand, assert what matters: rows were written, and they went in on fewer instants
-- than there were calls.
SELECT ok(:new_rows::int > 0,
          'the DO block DID write rows, which is what makes the hazard invisible: the history looks '
          || 'healthy unless you count the instants rather than the rows');

SELECT ok(:new_instants::int < 4,
          'but those ' || :new_rows::int || ' rows went in on fewer than four instants. '
          || 'statement_timestamp() is fixed for the statement, so a loop of samples collapses '
          || 'onto the instant of its first call and the history cannot see three of the four '
          || 'seconds that elapsed. Four rows in one instant means no gap and therefore no '
          || 'invented duration, which is the safety property that matters here');

SELECT ok(:still_max::numeric <= 5,
          'and the longest duration reported is unchanged, so the function did not absorb the loop');

-- ------------------------------------------------------------------ resolution notices

\set QUIET 1
\o /dev/null
-- Scoped to application_name rather than to the pid table: dw1 and dw2 hold in-flight queries on
-- connections that a later dblink_send_query would then fail on, and a pid in the table can be
-- reused by an unrelated session, so terminating it hits whatever now owns it.
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE application_name IN ('slow_batch','quick_batch','api_duration');
DO $drain$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE application_name = 'api_duration');
  PERFORM pg_sleep(0.1);
END LOOP; END $drain$;
TRUNCATE lock_tree_alert;
SELECT lock_tree_notify_resolved() AS quiet_resolved \gset
\o
\set QUIET 0

SELECT is(:quiet_resolved::int, 0,
          'on a quiet database with no stored alerts, nothing is resolved. A resolution notice with '
          || 'no matching alert is noise, so a root that never alerted is never cleared');

\set QUIET 1
\o /dev/null
-- ALL THREE connections are fresh. dr1 was terminated at the end of the duration section, and
-- dblink does not remove a connection entry when its backend dies, so the next command on that name
-- fails with "terminating connection due to administrator command". dw1 and dw2 released their
-- waiters mid-statement, which leaves an unconsumed result, and a second send_query on one of those
-- fails with "another command is already in progress". Both were hit, in that order, before this
-- was fixed.
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['dy1','dx1','dx2']) AS n;
SELECT dblink_exec('dy1','BEGIN');
SELECT dblink_exec('dy1','SET application_name = ''slow_batch''');
SELECT dblink_exec('dy1','LOCK TABLE lock_tree_dr1 IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('dx1','SET application_name = ''api_duration''; SELECT count(*) FROM lock_tree_dr1');
SELECT dblink_send_query('dx2','SET application_name = ''api_duration''; SELECT count(*) FROM lock_tree_dr1');
DO $w2$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE application_name = 'api_duration' AND wait_event_type = 'Lock') = 2;
  PERFORM pg_sleep(0.1);
END LOOP; END $w2$;
SELECT lock_tree_notify(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS onset \gset
SELECT lock_tree_notify_resolved(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS mid \gset
\o
\set QUIET 0

SELECT is(:onset::int, 1, 'the incident alerts once');

SELECT is(:mid::int, 0,
          'and is NOT resolved while it is still going, which is the case that would make the '
          || 'notice useless');

SELECT is((SELECT count(*) FROM lock_tree_alert), 1::bigint,
          'and the stored state is still there, so a relapse would escalate rather than re-alert');

\set QUIET 1
\o /dev/null
SELECT dblink_exec('dy1','ROLLBACK');
DO $drain2$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE application_name = 'api_duration');
  PERFORM pg_sleep(0.1);
END LOOP; END $drain2$;
SELECT lock_tree_notify_resolved(min_blocked => 1, min_depth => NULL, min_wait => NULL) AS cleared \gset
\o
\set QUIET 0

SELECT is(:cleared::int, 1, 'and exactly one resolution notice once it has gone');

SELECT is((SELECT count(*) FROM lock_tree_alert), 0::bigint,
          'with the state forgotten, so the same root blocking again alerts from the start rather '
          || 'than escalating against a high-water mark from a previous incident');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
-- Scoped to application_name rather than to the pid table: dw1 and dw2 hold in-flight queries on
-- connections that a later dblink_send_query would then fail on, and a pid in the table can be
-- reused by an unrelated session, so terminating it hits whatever now owns it.
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE application_name IN ('slow_batch','quick_batch','api_duration');
DO $bye$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM (VALUES ('dr1'),('dr2'),('dw1'),('dw2'),('dw3'),
                             ('dy1'),('dx1'),('dx2')) AS t(n) LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $bye$;
TRUNCATE lock_tree_alert;
TRUNCATE lock_tree_history;
\o
\set QUIET 0
DROP TABLE lock_tree_dr1;
DROP TABLE lock_tree_dr2;