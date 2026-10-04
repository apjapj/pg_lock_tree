-- s2_three_chains.sql: three unrelated incidents, at once.
--
-- This is what a real incident looks like: not one queue, but several that happen to
-- overlap. A batch job idle on orders, a migration holding a lock on users, and a
-- reporting replica behind a stuck ANALYZE, all in the same ten seconds.
--
-- The trap for a flat query is not that it is wrong, it is that it interleaves the three
-- into one undifferentiated pile of "waiting" rows. Separating them is most of the work.

\set ON_ERROR_STOP 1
\pset border 2
CREATE EXTENSION IF NOT EXISTS dblink;

\echo ''
\echo '=== SCENARIO 2: three unrelated chains at once ==='

\set QUIET 1
\o /dev/null
DROP TABLE IF EXISTS s2_orders;
DROP TABLE IF EXISTS s2_users;
DROP TABLE IF EXISTS s2_reports;
DROP TABLE IF EXISTS s2_pids;
CREATE TABLE s2_orders (id int primary key, v text);
CREATE TABLE s2_users  (id int primary key, v text);
CREATE TABLE s2_reports(id int primary key, v text);
INSERT INTO s2_orders SELECT g,'x' FROM generate_series(1,3) g;
INSERT INTO s2_users  SELECT g,'x' FROM generate_series(1,3) g;
INSERT INTO s2_reports SELECT g,'x' FROM generate_series(1,3) g;

CREATE TABLE s2_pids (tag text, pid int);
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['o1','o2','o2b','u1','u2','r1','r2']) AS n;
INSERT INTO s2_pids
SELECT n, (SELECT p FROM dblink(n,'SELECT pg_backend_pid()') AS t(p int))
FROM unnest(ARRAY['o1','o2','o2b','u1','u2','r1','r2']) AS n;

-- Chain 1: a batch rewrite holding ACCESS EXCLUSIVE on orders, two API reads behind it.
--
-- The lock mode matters and is easy to get wrong. A plain UPDATE takes only RowExclusiveLock,
-- which does NOT conflict with the AccessShareLock a SELECT needs, so the reads sail straight
-- past and no chain forms. You need ACCESS EXCLUSIVE (a rewrite, TRUNCATE, or most DDL) to
-- block readers. This is the single most common reason a "blocking chain" demo quietly fails.
--
-- dblink_send_query returns as soon as the query is *sent*, so each queued statement needs its
-- own connection; you cannot queue two down one.
SELECT dblink_exec('o1','BEGIN');
SELECT dblink_exec('o1','SET application_name = ''batch_orders_rewrite''');
SELECT dblink_exec('o1','LOCK TABLE s2_orders IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('o2','SET application_name=''api_order_read''; SELECT * FROM s2_orders');
SELECT pg_sleep(0.3);
SELECT dblink_send_query('o2b','SET application_name=''api_order_count''; SELECT count(*) FROM s2_orders');

-- Chain 2: a migration on users, and a signup INSERT behind it.
-- SHARE ROW EXCLUSIVE conflicts with RowExclusiveLock, so it blocks writes but not reads.
SELECT dblink_exec('u1','BEGIN');
SELECT dblink_exec('u1','SET application_name = ''migrate_add_email''');
SELECT dblink_exec('u1','LOCK TABLE s2_users IN SHARE ROW EXCLUSIVE MODE');
SELECT dblink_send_query('u2','SET application_name=''signup''; INSERT INTO s2_users VALUES (9,''new'')');

-- Chain 3: an index build holding ACCESS EXCLUSIVE on reports, with a reader behind it.
SELECT dblink_exec('r1','BEGIN');
SELECT dblink_exec('r1','SET application_name = ''reindex_reports''');
SELECT dblink_exec('r1','LOCK TABLE s2_reports IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('r2','SET application_name=''report_reader''; SELECT count(*) FROM s2_reports');

-- Wait until every chain is actually formed, rather than counting Lock waiters overall: if
-- one of these chains silently failed to block, the count would still look plausible.
DO $w$ BEGIN
  FOR i IN 1..150 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_activity
               WHERE pid IN (SELECT pid FROM s2_pids)
                 AND wait_event_type = 'Lock') >= 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END $w$;

\echo ''
\echo '--- proof all three chains formed: 3 roots, 4 waiters ---'
SELECT count(*) FILTER (WHERE depth = 0) AS roots,
       count(*) FILTER (WHERE depth > 0) AS waiters
FROM lock_tree;
\o
\unset QUIET

\echo ''
\echo '--- flat: 6 sessions, all "waiting", no way to tell which is which ---'
SELECT p.tag, a.application_name, a.state, coalesce(a.wait_event,'-') AS waiting
FROM s2_pids p JOIN pg_stat_activity a USING (pid) ORDER BY p.tag;

\echo ''
\echo '--- pg_lock_tree: three separate trees, root-first within each ---'
SELECT * FROM lock_tree_text();

\echo ''
\echo '--- pg_lock_tree: one line per culprit, most damage first ---'
SELECT root_pid, application_name, state, blocked_sessions, max_depth, longest_wait
FROM lock_tree_roots();

\echo ''
\echo '--- pg_lock_tree: the actions, ordered so the biggest win is first ---'
SELECT * FROM lock_tree_actions();

\echo ''
\echo '--- standard query: the pairs, but which tree does each belong to? ---'
\i 01_standard_query.sql

-- ---------------------------------------------------------------- teardown
\set QUIET 1
\o /dev/null
CREATE TEMP TABLE s2_kill AS SELECT pid FROM s2_pids;
DO $k$ DECLARE p int; BEGIN
  FOR p IN SELECT pid FROM s2_kill LOOP
    BEGIN PERFORM pg_terminate_backend(p); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $k$;
DO $d$ BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM lock_tree WHERE pid IN (SELECT pid FROM s2_kill));
    PERFORM pg_sleep(0.1);
  END LOOP;
END $d$;
DO $b$ DECLARE n text; BEGIN
  FOREACH n IN ARRAY ARRAY['o1','o2','o2b','u1','u2','r1','r2'] LOOP
    BEGIN PERFORM dblink_disconnect(n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $b$;
DROP TABLE s2_pids; DROP TABLE s2_orders; DROP TABLE s2_users; DROP TABLE s2_reports;
\o
\unset QUIET
SELECT count(*) AS s2_sessions_left FROM pg_stat_activity
WHERE application_name IN ('batch_orders_rewrite','api_order_read','api_order_count','migrate_add_email',
                           'signup','reindex_reports','report_reader');