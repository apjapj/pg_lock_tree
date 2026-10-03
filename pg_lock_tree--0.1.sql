/* pg_lock_tree--0.1.sql
 *
 * Readable lock-wait trees for PostgreSQL 14+.
 *   lock_tree          view: every session in a blocking chain, root first
 *   lock_tree_roots()  the head-of-line blockers, with how many sessions wait on each
 *   lock_tree_text()   the same tree as indented text, for psql during an incident
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 */

\echo Use "CREATE EXTENSION pg_lock_tree" to load this file. \quit

DO $check$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_lock_tree requires PostgreSQL 14 or later (needs pg_locks.waitstart)';
  END IF;
END
$check$;

CREATE VIEW @extschema@.lock_tree AS
WITH RECURSIVE
act AS (
  SELECT a.pid,
         a.usename::text           AS usename,
         a.datname::text           AS datname,
         a.application_name,
         a.client_addr,
         a.state,
         a.wait_event_type,
         a.wait_event,
         a.xact_start,
         a.state_change,
         a.query,
         CASE WHEN a.wait_event_type = 'Lock'
              THEN pg_blocking_pids(a.pid)
              ELSE '{}'::int[] END AS blocked_by
  FROM pg_stat_activity a
  WHERE a.pid IS NOT NULL
),
edge AS (                       -- one row per (blocked, blocker) pair
  SELECT a.pid AS blocked, b AS blocker
  FROM act a, unnest(a.blocked_by) AS b
),
root AS (                       -- blocks someone and is not itself blocked; pid 0 = a prepared transaction
  SELECT DISTINCT e.blocker AS pid
  FROM edge e
  LEFT JOIN act a ON a.pid = e.blocker
  WHERE a.pid IS NULL OR cardinality(a.blocked_by) = 0
),
walk AS (
  SELECT r.pid, r.pid AS root_pid, 0 AS depth, ARRAY[r.pid] AS path
  FROM root r
  UNION ALL
  SELECT e.blocked, w.root_pid, w.depth + 1, w.path || e.blocked
  FROM walk w
  JOIN edge e ON e.blocker = w.pid
  WHERE e.blocked <> ALL (w.path)          -- guard against transient wait-for cycles
),
placed AS (                     -- a waiter can sit behind several blockers: keep its deepest chain
  SELECT DISTINCT ON (pid) pid, root_pid, depth, path
  FROM walk
  ORDER BY pid, depth DESC, path
),
waiting AS (                    -- a backend waits for at most one heavyweight lock at a time
  SELECT DISTINCT ON (l.pid)
         l.pid,
         l.mode,
         l.locktype,
         l.waitstart,
         CASE
           WHEN l.relation IS NULL THEN NULL
           WHEN l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
             THEN l.relation::regclass::text
           ELSE 'relation ' || l.relation || ' in database ' || l.database   -- regclass only resolves in this database
         END AS relation
  FROM pg_locks l
  WHERE NOT l.granted
  ORDER BY l.pid, l.waitstart NULLS LAST
)
SELECT p.root_pid,
       p.depth,
       p.path,
       p.pid,
       coalesce(a.blocked_by, '{}'::int[])                                 AS blocked_by,
       coalesce(a.state, CASE WHEN p.pid = 0
                              THEN 'prepared transaction (see pg_prepared_xacts)'
                              ELSE 'exited' END)                           AS state,
       a.usename,
       a.datname,
       a.application_name,
       a.client_addr,
       a.wait_event_type,
       a.wait_event,
       CASE WHEN w.pid IS NULL THEN NULL
            ELSE w.mode || ' on ' || coalesce(w.relation, w.locktype) END   AS waiting_for,
       date_trunc('second', clock_timestamp() - w.waitstart)               AS wait_age,
       date_trunc('second', clock_timestamp() - a.xact_start)              AS xact_age,
       date_trunc('second', clock_timestamp() - a.state_change)            AS state_age,
       a.query
FROM placed p
LEFT JOIN act a   ON a.pid = p.pid
LEFT JOIN waiting w ON w.pid = p.pid
ORDER BY p.root_pid, p.path;

COMMENT ON VIEW @extschema@.lock_tree IS
  'Sessions in lock-wait chains. depth 0 = root blocker; path = chain from the root. '
  'Needs pg_read_all_stats (or superuser) to see other users'' queries.';


CREATE FUNCTION @extschema@.lock_tree_roots()
RETURNS TABLE (
  root_pid          int,
  state             text,
  usename           text,
  datname           text,
  application_name  text,
  xact_age          interval,
  state_age         interval,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  query             text,
  suggested_action  text
)
LANGUAGE sql STABLE
AS $$
  SELECT r.pid,
         r.state,
         r.usename,
         r.datname,
         r.application_name,
         r.xact_age,
         r.state_age,
         count(t.pid) FILTER (WHERE t.depth > 0),
         max(t.depth),
         max(t.wait_age),
         r.query,
         CASE
           WHEN r.state LIKE 'idle in transaction%'
             THEN format('Idle in an open transaction. SELECT pg_terminate_backend(%s);', r.pid)
           ELSE format('Try SELECT pg_cancel_backend(%s); then pg_terminate_backend(%s) if it does not clear.',
                       r.pid, r.pid)
         END
  FROM @extschema@.lock_tree r
  JOIN @extschema@.lock_tree t ON t.root_pid = r.pid
  WHERE r.depth = 0
  GROUP BY r.pid, r.state, r.usename, r.datname, r.application_name,
           r.xact_age, r.state_age, r.query
  ORDER BY count(t.pid) DESC, r.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_roots() IS
  'Head-of-line blockers, most sessions blocked first, with a suggested next step.';


CREATE FUNCTION @extschema@.lock_tree_text(query_width int DEFAULT 60)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN depth = 0
           THEN format('%s  [%s, xact %s]  %s (%s@%s)  %s',
                       pid, state, coalesce(xact_age::text, '-'),
                       coalesce(nullif(application_name, ''), '-'),
                       coalesce(usename, '?'), coalesce(datname, '?'),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
           ELSE format('%s└─ %s  waits %s for %s  %s',
                       repeat('   ', depth - 1), pid,
                       coalesce(wait_age::text, '?'), coalesce(waiting_for, wait_event),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
         END
  FROM @extschema@.lock_tree
  ORDER BY root_pid, path
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_text(int) IS
  'The lock tree as indented text lines, for reading in psql.';
