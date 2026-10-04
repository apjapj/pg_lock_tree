-- s4_wide_queue.sql — a hobbled database. This is the case that decides whether a tool is
-- usable or not.
--
-- Sixty sessions waiting behind one idle transaction. Nothing clever is happening: it is a
-- batch job that forgot to commit, and now the whole application is queued behind it.
--
-- The question is not "can you find the culprit" — you can, in the first row. The question is
-- whether the tool lets you *read* the answer, and then act on it without scrolling. That is
-- what this scenario measures: line widths, how many lines you have to read past, and whether
-- the fix arrives on its own.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 4: one idle transaction, 60 sessions behind it ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s4_t;
DROP TABLE IF EXISTS s4_pids;
CREATE TABLE s4_t (id int primary key, v text);
INSERT INTO s4_t SELECT g,'v'||g FROM generate_series(1,5) g;
CREATE TABLE s4_pids (tag text, pid int);

-- 1 culprit + 60 waiters. Build the tag list with generate_series rather than a plpgsql
-- ARRAY constructor, so it is visible to SQL as well as to DO.
CREATE TEMP TABLE s4_tags AS
SELECT n FROM (SELECT 'culprit'::text AS n
               UNION ALL SELECT 'w'||g FROM generate_series(1,60) g) t;

SELECT dblink_connect(t.n, format('dbname=%s user=%s', current_database(), current_user))
FROM s4_tags t;
INSERT INTO s4_pids
SELECT t.n, (SELECT p FROM dblink(t.n,'SELECT pg_backend_pid()') AS s(p int))
FROM s4_tags t;

SELECT dblink_exec('culprit','BEGIN');
SELECT dblink_exec('culprit','SET application_name = ''nightly_reconciliation''');
SELECT dblink_exec('culprit','LOCK TABLE s4_t IN ACCESS EXCLUSIVE MODE');

-- Queue the waiters a few at a time: 60 concurrent send_query calls in one statement is slow
-- enough to be worth batching.
DO $q$
DECLARE i int;
BEGIN
  FOR i IN 1..60 LOOP
    PERFORM dblink_send_query('w'||i,
      format('SET application_name = ''api_worker_%s''; SELECT count(*) FROM s4_t', lpad(i::text,2,'0')));
  END LOOP;
END
$q$;

DO $w$ BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s4_pids) AND wait_event_type='Lock') >= 55;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;
\o
\unset QUIET

\echo ''
\echo '--- scale of the incident ---'
SELECT count(*) FILTER (WHERE depth = 0) AS roots,
       count(*) FILTER (WHERE depth > 0) AS waiters
FROM lock_tree;

\echo ''
\echo '--- pg_lock_tree: the answer, in full, unabbreviated. 61 lines. ---'
\echo '    (only the first 4 and the last 2 shown; the middle is 55 more of the same)'
SELECT * FROM lock_tree_text() OFFSET 0 LIMIT 4;
\echo '    ... 55 more identical lines ...'
SELECT * FROM lock_tree_text() OFFSET 59;

\echo ''
\echo '--- the same tree, abbreviated: lock_tree_text_short() ---'
\echo '    (only the first 4 and the last 2 shown)'
SELECT * FROM lock_tree_text_short() OFFSET 0 LIMIT 4;
\echo '    ... 55 more identical lines ...'
SELECT * FROM lock_tree_text_short() OFFSET 59;

\echo ''
\echo '--- width comparison, which is the whole point ---'
-- Width is the point of the abbreviated form, so measure it rather than assert it.
-- Cross-join by row position: both forms are ordered root-first, so line N of one
-- corresponds to line N of the other.
--
-- What each column actually is, because getting this wrong would be easy and would
-- overstate the result:
--   lock_tree_text()            default width 60, full lock modes, full state names
--   lock_tree_lines(100,false)  full names, roomier query column
--   lock_tree_lines(100,true)   abbreviated modes and states, roomier query column
--
-- The compact interval (lock_tree_age: "1m30s" not "00:01:30") is in ALL THREE. It is a
-- change to the renderer, not to the short flag, so it cannot be isolated by comparing
-- these three columns — it is a separate saving that applies to the unabbreviated form too.
WITH long_form  AS (SELECT row_number() OVER () AS n, length(t) AS w FROM lock_tree_text() t),
     full_wide  AS (SELECT row_number() OVER () AS n, length(t) AS w FROM lock_tree_lines(100, false) t),
     short_form AS (SELECT row_number() OVER () AS n, length(t) AS w FROM lock_tree_lines(100, true) t)
SELECT count(*)                                        AS lines,
       round(avg(l.w))                                AS avg_full_default,
       round(avg(f.w))                                AS avg_full_wide,
       round(avg(s.w))                                AS avg_abbrev_wide,
       max(f.w)                                       AS max_full_wide,
       max(s.w)                                       AS max_abbrev_wide,
       round(100.0 * (avg(f.w) - avg(s.w)) / avg(f.w)) AS pct_saved_by_abbrev
FROM long_form l JOIN full_wide f USING (n) JOIN short_form s USING (n);

\echo ''
\echo '   and what the abbreviations cost in clarity, which is the real trade:'
\echo '     AccessExclusiveLock -> AX      idle in transaction -> idle-in-tx'
\echo '     AX and RS and SRX are the conventional PostgreSQL/Oracle-era abbreviations;'
\echo '     anything not in the table (transactionid, tuple, advisory) is left alone rather'
\echo '     than guessed at, so an unfamiliar value is never silently abbreviated.'

\echo ''
\echo '--- the culprit, and the fix ---'
SELECT root_pid, application_name, state, blocked_sessions, max_depth, longest_wait
FROM lock_tree_roots();

\echo ''
\echo '--- the published CTE on 60 blocked sessions ---'
\i 01_standard_query.sql

\echo ''
\echo '--- coverage at scale, all three (the published CTE has now run) ---'
WITH waiting AS (SELECT DISTINCT pid FROM pg_stat_activity WHERE wait_event_type='Lock')
SELECT (SELECT count(*) FROM waiting) AS actually_waiting,
       (SELECT count(*) FROM std_result WHERE blocked_pid IN (SELECT pid FROM waiting)) AS reported_by_standard,
       (SELECT count(*) FROM lock_tree WHERE pid IN (SELECT pid FROM waiting)) AS reported_by_pg_lock_tree;

\echo ''
\echo '--- one command, and the whole queue drains ---'
SELECT * FROM lock_tree_actions();

\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(root_pid) FROM lock_tree_roots();
DO $d$ BEGIN
  FOR i IN 1..300 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s4_pids));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOR n IN SELECT t.n FROM s4_tags t LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s4_pids; DROP TABLE s4_t;
\o
\unset QUIET
SELECT count(*) AS s4_sessions_left FROM pg_stat_activity WHERE application_name LIKE 'api_worker_%';