-- test/17_duration_by_application.sql: the aggregation a page actually needs, and the three columns
-- 0.12 could not get right.
--
-- TWO SUBJECTS, one file, because they are one correction.
--
-- 0.12's lock_tree_duration() reported three columns that could not be right:
--
--   longest_wait            always NULL, because query_id is on the root row and wait_age is on
--                           the waiter's, so the rows carrying one carry no instance of the other
--   blocked_sessions_peak   always 1, because it counted ROOT rows per query per sample and there
--                           is exactly one root row per query per sample
--   sessions_total          that same 1 summed, which made it a second copy of samples
--
-- One join fixes all three: the root rows of a sample matched to the waiter rows of the SAME sample
-- on root_pid and root_object. This file asserts the corrected values against the samples
-- themselves rather than against constants, so a fixture change does not silently pass.
--
-- And lock_tree_duration_by_application() is NOT lock_tree_duration() summed by application. Where
-- an application hands the queue from one statement to another, the per-query figures discard every
-- gap that straddles the handover and the per-application figure counts all of them. The second half
-- of this file builds exactly that and asserts the two disagree.
--
-- Needs superuser, dblink, and max_prepared_transactions untouched.
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

-- Unique names. Several files build chains and two of them creating the same relation is how a
-- suite starts failing for reasons unrelated to what it tests.
DROP TABLE IF EXISTS app_t1;
DROP TABLE IF EXISTS app_t2;
DROP TABLE IF EXISTS app_t3;
CREATE TABLE app_t1 (id int);
CREATE TABLE app_t2 (id int);
CREATE TABLE app_t3 (id int);

-- Three tables, not two, and deliberately. query_id identifies a STATEMENT, so if nightly_job's
-- post-handover statement were textually identical to the one reporting was already running, the
-- two would share a query_id and lock_tree_duration() would report one row for both applications.
-- That is correct behaviour for a per-statement view and it is what makes the comparison in this
-- file meaningless, so the fixture gives every application a statement of its own.

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['a1','a2','a3','a4','w1','w2','w3']) AS n;
CREATE TEMP TABLE ap AS
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int)) AS pid
FROM unnest(ARRAY['a1','a2','a3','a4','w1','w2','w3']) AS s(n);

SELECT dblink_exec('a1','BEGIN');
SELECT dblink_exec('a1','SET application_name = ''nightly_job''');
SELECT dblink_exec('a1','LOCK TABLE app_t1 IN ACCESS EXCLUSIVE MODE');
-- Two applications, so the ranking is not a tie and the join on application_name is exercised with
-- more than one value.
SELECT dblink_exec('a2','BEGIN');
SELECT dblink_exec('a2','SET application_name = ''reporting''');
SELECT dblink_exec('a2','LOCK TABLE app_t2 IN ACCESS EXCLUSIVE MODE');
-- Each sample must be its own statement: statement_timestamp() is fixed for the statement, so a
-- loop would collapse them onto one instant and there would be no gap to sum.
SELECT dblink_send_query('w1','SET application_name = ''api''; SELECT count(*) FROM app_t1');
SELECT dblink_send_query('w2','SET application_name = ''api''; SELECT count(*) FROM app_t1');
SELECT dblink_send_query('w3','SET application_name = ''api''; SELECT count(*) FROM app_t2');
DO $w$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
              WHERE application_name = 'api' AND wait_event_type = 'Lock') = 3;
  PERFORM pg_sleep(0.1);
END LOOP; END $w$;
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();

\o
\set QUIET 0

SELECT plan(21);

SELECT has_function('lock_tree_duration_by_application', ARRAY['interval'],
                    'lock_tree_duration_by_application(interval) exists');

-- --------------------------------------------------------- the three columns 0.13 fixes

\set QUIET 1
\o /dev/null
-- The truth, computed from the samples rather than asserted as a constant: at every instant there
-- is one root per application and three waiter rows beneath it.
CREATE TEMP TABLE truth AS
SELECT r.application_name,
       r.sampled_at,
       -- w.depth > 0, and it is the whole point. Without it this subquery matched the root row to
       -- ITSELF and agreed with the very bug it was written to check, which is how a peak that was
       -- one too high survived a test that asserted it. An expectation derived from the expression
       -- under test is not an expectation.
       (SELECT count(*) FROM lock_tree_history w
         WHERE w.sampled_at = r.sampled_at
           AND w.root_pid = r.root_pid
           AND w.depth > 0
           AND coalesce(w.root_object, '') = coalesce(r.root_object, '')) AS waiters,
       (SELECT max(w.wait_age) FROM lock_tree_history w
         WHERE w.sampled_at = r.sampled_at
           AND w.root_pid = r.root_pid
           AND w.depth > 0
           AND coalesce(w.root_object, '') = coalesce(r.root_object, '')) AS longest
  FROM lock_tree_history r
 WHERE r.depth = 0;
SELECT count(DISTINCT sampled_at) AS instants, max(waiters) AS truth_peak FROM truth \gset
SELECT array_length(array_agg(DISTINCT application_name), 1) AS n_apps FROM truth \gset
SELECT count(*) AS duration_rows FROM lock_tree_duration() \gset
SELECT max(blocked_sessions_peak) AS dur_peak, max(sessions_total) AS dur_total,
       count(*) FILTER (WHERE longest_wait IS NOT NULL) AS dur_wait_rows,
       count(*) AS dur_all_rows
  FROM lock_tree_duration() \gset
\o
\set QUIET 0

SELECT is(:instants::int, 4, 'four sample instants, so gaps exist to sum');

SELECT is(:n_apps::int, 2, 'and two applications standing at once');

SELECT is(:truth_peak::int, 2,
          'the truth from the samples: TWO sessions were blocked behind nightly_job''s root, w1 and'
          || ' w2, while reporting''s root has only w3. It read 3 until 0.15 fixed the self-join, because'
          || ' the root was counted among its own waiters');

-- Take reporting's root away now and keep sampling. Without this both applications have held for
-- exactly the same instants and "ranked worst first" is an assertion about a tie.
\set QUIET 1
\o /dev/null
SELECT dblink_exec('a2','ROLLBACK');
DO $dr$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'reporting');
  PERFORM pg_sleep(0.1);
END LOOP; END $dr$;
SELECT pg_sleep(1.2);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();
\o
\set QUIET 0

-- The three that were wrong. Each compared against the value computed from the samples above, so
-- these assert the join rather than a number that happens to be right today.
SELECT is(:dur_peak::int, :truth_peak::int,
          'blocked_sessions_peak is now the number of sessions actually blocked, and 0.12 reported'
          || ' 1 for this fixture no matter what it contained');

SELECT is(:dur_total::int, :truth_peak::int * :instants::int,
          'sessions_total is that peak summed over the instants, not a second copy of samples. Both '
          || 'figures were one too high per sample until 0.15, because the root row was counted '
          || 'among its own waiters');

SELECT is(:dur_wait_rows::int, :dur_all_rows::int,
          'every row has a non-NULL longest_wait. In 0.12 it was always NULL, because query_id is on '
          || 'the root row and wait_age is on the waiter''s, so no single row had both');

-- ------------------------------------------------------ per application, and why it differs

\set QUIET 1
\o /dev/null
SELECT count(*) AS by_app_rows FROM lock_tree_duration_by_application() \gset
SELECT count(*) AS nightly_rows FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
SELECT array_length(query_ids, 1) AS nightly_qids FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
SELECT blocking_seconds AS nightly_seconds FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
SELECT blocking_seconds AS reporting_seconds FROM lock_tree_duration_by_application()
 WHERE application_name = 'reporting' \gset
SELECT blocked_sessions_peak AS nightly_peak FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
-- Each gap contributes one entry per distinct application rooted at its NEAR end, whether that
-- gap ends up counted or discarded. Computed from the samples rather than asserted as a constant.
WITH instants AS (SELECT DISTINCT sampled_at FROM lock_tree_history),
spans AS (SELECT sampled_at AS f, lead(sampled_at) OVER (ORDER BY sampled_at) AS t FROM instants)
SELECT coalesce(sum(n), 0) AS expected_gaps FROM (
  SELECT count(DISTINCT r.application_name) AS n
  FROM spans s
  JOIN lock_tree_history r ON r.sampled_at = s.f AND r.depth = 0
  WHERE s.t IS NOT NULL AND r.application_name IS NOT NULL
  GROUP BY s.f) q \gset
\o
\set QUIET 0

SELECT is(:by_app_rows::int, 2, 'one row per application, so two');

SELECT is(:nightly_rows::int, 1, 'and exactly one row for the application asked about');

SELECT ok(:nightly_qids::int >= 1,
          'reporting the statement it was root for, so the application can be traced to code');

SELECT is(:nightly_peak::int, :truth_peak::int,
          'the same corrected peak as the per-query figure, since the join is the same');

SELECT ok(:nightly_seconds::numeric > :reporting_seconds::numeric,
          'and ranked worst first by duration: nightly_job blocked for ' || :nightly_seconds ||
          's against reporting''s ' || :reporting_seconds || 's. This is the only ordering anyone '
          || 'reads it in, and the two applications have to differ for it to mean anything');

-- Every gap is accounted for, counted or discarded. Per application, an application that was the
-- root at the near end of a gap contributes one gap for it.
\set QUIET 1
\o /dev/null
SELECT sum(gaps + gaps_excluded) AS accounted FROM lock_tree_duration_by_application() \gset
\o
\set QUIET 0

SELECT is(:accounted::int, :expected_gaps::int,
          'gaps plus gaps_excluded equals the (gap, application at its near end) pairs computed '
          || 'from the samples, so every gap is either counted or discarded and none is lost');

-- The whole reason this function exists: a handover inside the observed window.
\set QUIET 1
\o /dev/null
SELECT dblink_exec('a1','COMMIT');
SELECT dblink_exec('a1','BEGIN');
SELECT dblink_exec('a1','LOCK TABLE app_t3 IN ACCESS EXCLUSIVE MODE');
SELECT pg_sleep(1.2);
-- The waiters move with it: app_t1 is free now, so they re-queue on app_t3.
SELECT dblink_disconnect('w1');
SELECT dblink_disconnect('w2');
SELECT dblink_connect('w1', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_connect('w2', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_send_query('w1','SET application_name = ''api''; SELECT count(*) FROM app_t3');
SELECT dblink_send_query('w2','SET application_name = ''api''; SELECT count(*) FROM app_t3');
DO $w2$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
              WHERE application_name = 'api' AND wait_event_type = 'Lock') >= 2;
  PERFORM pg_sleep(0.1);
END LOOP; END $w2$;
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();
\o
\set QUIET 0

\set QUIET 1
\o /dev/null
-- Two statements for nightly_job now, and the per-query figure has lost the gap that crossed the
-- handover. Record the numbers rather than assuming their signs.
SELECT count(*) AS qids_nightly FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' AND array_length(query_ids, 1) = 2 \gset
-- ONLY nightly_job's own statements, matched through query_ids. Summing every per-query figure and
-- comparing it against one application compares two different questions.
SELECT coalesce(sum(d.blocking_seconds), 0) AS summed_per_query
  FROM lock_tree_duration() d
  JOIN lock_tree_duration_by_application() a ON d.query_id = ANY (a.query_ids)
 WHERE a.application_name = 'nightly_job' \gset
SELECT blocking_seconds AS per_app_seconds FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
SELECT sum(gaps) AS nightly_gaps FROM lock_tree_duration_by_application()
 WHERE application_name = 'nightly_job' \gset
\o
\set QUIET 0

SELECT ok(:qids_nightly::int = 1,
          'the application is now recorded against two different statements, which is what a batch'
          || ' job running a fixed script looks like');

-- THE ASSERTION THIS FILE EXISTS FOR. Per application is strictly greater than the sum of per
-- query, because the per-query figure discarded every gap that straddled the handover.
SELECT ok(:per_app_seconds::numeric > :summed_per_query::numeric,
          'per-application seconds (' || :per_app_seconds || ') exceed the sum of the per-query '
          || 'seconds for the SAME statements (' || :summed_per_query || '), by ' ||
          round(:per_app_seconds::numeric - :summed_per_query::numeric, 3) ||
          's. That difference is the gap across the handover, which the per-query rule discards and '
          || 'the per-application rule counts. Summing the per-query figures by application would '
          || 'understate this one by that much');

SELECT ok(:nightly_gaps::int >= 3,
          'and the per-application figure counted ' || :nightly_gaps || ' gaps for it across one '
          || 'continuous period at the head of the queue, where its two statements could each only '
          || 'count the gaps on their own side of the handover');

-- A window that excludes every sample reports nothing, which is what makes the arguments above
-- meaningful: they are about this history and not about any history.
\set QUIET 1
\o /dev/null
SELECT count(*) AS narrow FROM lock_tree_duration_by_application(interval '1 millisecond') \gset
\o
\set QUIET 0

SELECT is(:narrow::int, 0, 'a window excluding every sample reports no rows');

-- One query_id, two applications. query_id identifies a STATEMENT, and two sessions running
-- identical text share it, which is what happens the moment two parts of a system do the same thing.
-- Measured, not assumed: it is why this fixture gives every application its own statement, and it is
-- a difference in meaning between the two functions rather than a rounding detail.
--
-- Written straight into the history, because this is a property of the AGGREGATION and not of the
-- locking: what matters is that the same query_id appears under two application_names, and building
-- two real sessions to produce that would add flakiness without testing anything more.
\set QUIET 1
\o /dev/null
-- Roots AND their waiters together, each waiter at its own root's instant. The first version put all
-- four waiters at ONE instant, which is where the last root was, so only that root's waiter matched
-- and only one of the two applications appeared. service_alpha holds first and then hands the same
-- statement to service_beta, so the gap between them is a handover of ONE statement between two
-- services, which is the case where the two duration functions invert.
WITH base AS (SELECT max(sampled_at) + interval '20 minutes' AS at FROM lock_tree_history),
k(n, off, app) AS (VALUES (0, interval '0', 'service_alpha'),
                           (1, interval '1 second', 'service_alpha'),
                           (2, interval '2 seconds', 'service_beta'),
                           (3, interval '3 seconds', 'service_beta')),
roots AS (SELECT b.at + k.off AS at, k.n, k.app FROM base b CROSS JOIN k)
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, query, query_id, root_object)
SELECT at, 90000 + n, 0, 90000 + n, 'idle in transaction', interval '0', app,
       'UPDATE ledger SET amount = amount WHERE id = 1', 7770000000000000001, NULL
  FROM roots
UNION ALL
SELECT at, 90000 + n, 1, 95000 + n, 'active', make_interval(secs => n * 3), 'api', 'SELECT 1',
       NULL, NULL
  FROM roots;
SELECT count(*) AS shared_query_rows FROM lock_tree_duration() WHERE query_id = 7770000000000000001 \gset
SELECT count(*) AS alpha_rows FROM lock_tree_duration_by_application()
 WHERE application_name = 'service_alpha' AND 7770000000000000001 = ANY(query_ids) \gset
SELECT count(*) AS beta_rows FROM lock_tree_duration_by_application()
 WHERE application_name = 'service_beta' AND 7770000000000000001 = ANY(query_ids) \gset
SELECT blocking_seconds AS shared_seconds FROM lock_tree_duration() WHERE query_id = 7770000000000000001 \gset
SELECT coalesce(sum(blocking_seconds), 0) AS split_seconds FROM lock_tree_duration_by_application()
 WHERE application_name IN ('service_alpha', 'service_beta') \gset
\o
\set QUIET 0

SELECT is(:shared_query_rows::int, 1,
          'the same statement run by two applications is ONE row in lock_tree_duration(), because '
          || 'query_id identifies the statement and not who ran it');

SELECT is(:alpha_rows::int + :beta_rows::int, 2,
          'and TWO rows in lock_tree_duration_by_application(), because that view keys on the '
          || 'application as well. This is the difference between the two figures, and it is a '
          || 'difference in meaning rather than in rounding');

-- The comparison INVERTS here, and that is worth pinning rather than glossing over.
--
-- For the same statement, the per-query figure is the LARGER one: the statement is literally
-- identical on both sides of the handover, so every gap has it at both ends and the per-query rule
-- counts them all. The per-application rule DISCARDS the handover gap, because from service_alpha's
-- point of view it stopped blocking at instant 1 and from service_beta's it only started at
-- instant 2, and neither owned the gap between them.
--
-- So neither figure is "the right one". The per-query one is right when you want to know what this
-- STATEMENT costs, including the time it spent blocking under two different applications. The
-- per-application one is right when you want to know what each service cost, and it is lower
-- because a handover is not attributable to either party.
SELECT ok(:shared_seconds::numeric > :split_seconds::numeric,
          'for the SAME statement the per-query figure is the larger one (' || :shared_seconds ||
          's against ' || :split_seconds || 's), because the statement is identical on both sides '
          || 'of the handover so every gap has it at both ends, while the per-application rule '
          || 'discards that gap as attributable to neither service. The earlier assertion is the '
          || 'opposite case: a handover between DIFFERENT statements inside ONE application. '
          || 'Neither figure is wrong; they answer different questions');

-- The empty application_name is a category of its own, not a row to be dropped.
\set QUIET 1
\o /dev/null
-- A root whose session never called SET application_name. Recorded with the empty string, which is
-- what pg_stat_activity reports and is NOT NULL, so the function must not filter on it.
-- TWO instants, not one. A gap is keyed on the application being rooted at its NEAR end, so a
-- single isolated sample is never a blocker by this measure and would not appear at all. That is
-- the same rule that discards the trailing interval everywhere else.
-- TWO roots at two instants, each with its own waiter at that same instant. The first version had
-- one row at depth 0 and one at depth 1, which put the application at a single instant; a gap is
-- keyed on the application being rooted at its NEAR end, so one instant means no gap and no row.
-- The assertion below failed with zero, which read like a bug in the function and was a bug here.
WITH base AS (SELECT max(sampled_at) + interval '10 minutes' AS at FROM lock_tree_history),
k(n, off, depth) AS (VALUES (0, interval '0', 0), (1, interval '2 seconds', 0),
                           (2, interval '0', 1), (3, interval '2 seconds', 1))
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, state, wait_age,
                               application_name, query, root_object)
SELECT b.at + k.off, 99991, k.depth, 99991 + k.n,
       CASE WHEN k.depth = 0 THEN 'idle in transaction' ELSE 'active' END,
       CASE WHEN k.depth = 0 THEN interval '0' ELSE interval '7 seconds' END,
       '', CASE WHEN k.depth = 0 THEN 'VACUUM' ELSE 'SELECT 1' END, NULL
  FROM base b CROSS JOIN k;
SELECT count(*) AS unlabelled FROM lock_tree_duration_by_application()
 WHERE application_name = '' \gset
\o
\set QUIET 0

SELECT is(:unlabelled::int, 1,
          'a blocker that never set application_name is reported as its own row rather than '
          || 'dropped, because a blocker with no name is itself a finding');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE application_name IN ('nightly_job', 'reporting', 'api');
DO $drain$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE application_name IN ('nightly_job','reporting','api'));
  PERFORM pg_sleep(0.1);
END LOOP; END $drain$;
DO $bye$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM (VALUES ('a1'),('a2'),('a3'),('a4'),
                          ('w1'),('w2'),('w3')) AS t(n) LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $bye$;
TRUNCATE lock_tree_history;
DROP TABLE app_t1;
DROP TABLE app_t2;
DROP TABLE app_t3;
\o
\set QUIET 0