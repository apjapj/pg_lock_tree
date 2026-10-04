-- The query a DBA actually pastes — and what happens when you run it.
--
-- This is the recursive pg_locks() lock-tree query that circulates as a PostgreSQL wiki
-- entry and in a dozen blog posts. It is inlined rather than linked so the comparison does
-- not depend on a URL, and kept as close to the published form as possible — because the
-- point is to measure what that form gives and does not give.
--
-- Part 1 runs it verbatim. It is expected to time out, and that is the finding: the
-- published form omits `blocking_locks.granted`, so every ungranted lock joins with every
-- other lock of the same identity, blockers included. Each recursion level multiplies that,
-- and the row count grows geometrically with chain depth. Five sessions is enough to hang it.
--
-- Part 2 reruns it with that one line added. That is the version people converge on after
-- the first incident, and it works.
--
-- Part 3 counts coverage: how many of the sessions genuinely waiting did each side report.

\echo ''
\echo '   --- part 1: the published form, verbatim ---'
\echo '   expected to time out; that is the finding'
\set ON_ERROR_STOP off
SET statement_timeout = '3s';
CREATE TEMP TABLE std_naive AS
WITH RECURSIVE
locks AS (
    SELECT blocked_locks.pid AS blocked_pid,
           blocking_locks.pid AS blocking_pid
    FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_locks blocking_locks
      ON blocking_locks.locktype = blocked_locks.locktype
     AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
     AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
     AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
     AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
     AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
     AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
     AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
     AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
     AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
     AND blocking_locks.pid <> blocked_locks.pid
    WHERE NOT blocked_locks.granted
),
lock_chains AS (
    SELECT blocked_pid, blocking_pid, 1 AS depth
    FROM locks
    UNION ALL
    SELECT l.blocked_pid, l.blocking_pid, lc.depth + 1
    FROM locks l
    JOIN lock_chains lc ON l.blocked_pid = lc.blocking_pid
    WHERE lc.depth < 20
)
SELECT count(*) AS rows FROM lock_chains;
RESET statement_timeout;
\set ON_ERROR_STOP on

\echo ''
\echo '   --- part 2: the same query plus one line: AND blocking_locks.granted ---'
\o /dev/null
DROP TABLE IF EXISTS std_pids;
CREATE TABLE std_pids (tag text, pid int);
\o
-- Kept in a temp table so the scenario that included this file can still read the result
-- afterwards, e.g. to report coverage after both tools have run. Without that, the
-- comparison is only "which output looks nicer".
DROP TABLE IF EXISTS std_result;
CREATE TEMP TABLE std_result AS
WITH RECURSIVE
locks AS (
    SELECT blocked_locks.pid AS blocked_pid,
           blocking_locks.pid AS blocking_pid
    FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_locks blocking_locks
      ON blocking_locks.locktype = blocked_locks.locktype
     AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
     AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
     AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
     AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
     AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
     AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
     AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
     AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
     AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
     AND blocking_locks.pid <> blocked_locks.pid
    WHERE NOT blocked_locks.granted
      AND blocking_locks.granted          -- the missing line
),
lock_chains AS (
    SELECT blocked_pid, blocking_pid, 1 AS depth
    FROM locks
    UNION ALL
    SELECT l.blocked_pid, l.blocking_pid, lc.depth + 1
    FROM locks l
    JOIN lock_chains lc ON l.blocked_pid = lc.blocking_pid
    WHERE lc.depth < 20
)
SELECT blocking_pid AS root_pid, blocked_pid, depth FROM lock_chains;

\echo ''
\echo '   what it found (blocking_pid, blocked_pid, depth):'
SELECT * FROM std_result ORDER BY root_pid, blocked_pid;

\echo ''
\echo '   --- part 3: coverage. Who reported the sessions that are genuinely stuck? ---'
\echo ''
\echo '   Counting: a session counts as reported if it appears in the output AND is actually'
\echo '   waiting right now. Deliberately NOT "rows where depth > 0" — in a deadlock both'
\echo '   sessions are roots, so a depth-based count would score pg_lock_tree at zero for'
\echo '   reporting both of them correctly. That would be a misleading number, not a true one.'
WITH waiting AS (
    SELECT DISTINCT pid FROM pg_stat_activity WHERE wait_event_type = 'Lock'
)
SELECT (SELECT count(*) FROM waiting)                                     AS actually_waiting,
       (SELECT count(*) FROM waiting w WHERE EXISTS (
            SELECT 1 FROM std_result s WHERE s.blocked_pid = w.pid))       AS reported_by_standard,
       (SELECT count(*) FROM waiting w WHERE EXISTS (
            SELECT 1 FROM lock_tree t WHERE t.pid = w.pid))                AS reported_by_pg_lock_tree;

\echo ''
\echo '   and what each side gives you for the root itself:'
\echo '   standard     : a pid and a depth. No state, no query, no application_name,'
\echo '                  no idea whether to cancel or terminate.'
\echo '   pg_lock_tree : pid, state, query, application_name, how many sessions it blocks,'
\echo '                  and a ready-made command.'