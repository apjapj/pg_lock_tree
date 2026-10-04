/* pg_lock_tree--0.2.sql
 *
 * Readable lock-wait trees for PostgreSQL 14+.
 *   lock_tree              view: every session in a blocking chain, root first
 *   lock_tree_roots()      the head-of-line blockers, with how many sessions wait on each
 *   lock_tree_text()       the same tree as indented text, for psql during an incident
 *   lock_tree_text_short() the same, with abbreviations, for when the queue is wide
 *   lock_tree_actions()    copy-and-paste commands for the blockers, on their own lines
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 0.2 changes the text rendering only. The view's columns and values are unchanged and
 * still carry the full, unabbreviated names; abbreviation is opt-in, in the text
 * functions, so nothing that greps on 'AccessExclusiveLock' breaks.
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
seed AS (                       -- every blocker can head a chain...
  SELECT DISTINCT e.blocker AS pid
  FROM edge e
),
root AS (                       -- ...but only an unblocked blocker is a real head of the queue;
  SELECT s.pid                  -- pid 0 is not in pg_stat_activity, so a prepared transaction
  FROM seed s                   -- (which holds its locks until COMMIT PREPARED) qualifies here
  LEFT JOIN act a ON a.pid = s.pid
  WHERE a.pid IS NULL OR cardinality(a.blocked_by) = 0
),
walk AS (
  -- Seeding from every blocker, not just the unblocked ones, means a component with no
  -- unblocked blocker at all (a deadlock: everybody in it waits on somebody else in it)
  -- is still reported, as one depth-0 root per member, instead of vanishing. Rooting from
  -- the unblocked blockers alone would drop the whole component, because the cycle has no
  -- head. `rooted` records whether this chain descends from a real head of the queue.
  SELECT s.pid, s.pid AS root_pid, 0 AS depth, ARRAY[s.pid] AS path,
         (r.pid IS NOT NULL) AS rooted
  FROM seed s
  LEFT JOIN root r ON r.pid = s.pid
  UNION ALL
  SELECT e.blocked, w.root_pid, w.depth + 1, w.path || e.blocked, w.rooted
  FROM walk w
  JOIN edge e ON e.blocker = w.pid
  WHERE e.blocked <> ALL (w.path)          -- guard against transient wait-for cycles
),
placed AS (                     -- a waiter can sit behind several blockers: keep its deepest chain
  SELECT DISTINCT ON (pid) pid, root_pid, depth, path
  FROM walk
  -- deepest chain from a real root first; otherwise the session's own seed, so that a
  -- deadlock member stays visible at depth 0 instead of hiding inside a sibling's chain
  ORDER BY pid, rooted DESC, (root_pid = pid) DESC, depth DESC, path
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
  'Names are unabbreviated; see lock_tree_text_short() for a compact rendering. '
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


--------------------------------------------------------------------------------
-- formatting helpers
--------------------------------------------------------------------------------

-- 00:01:30 -> 1m30s. An eight-character timestamp eats a third of a tree line and tells
-- you less than "1m30s" does at a glance, especially when the interesting question is
-- "is this three seconds or three minutes".
CREATE FUNCTION @extschema@.lock_tree_age(i interval)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
           WHEN i IS NULL THEN '-'
           WHEN i < interval '1 minute' THEN format('%ss', trunc(extract(epoch FROM i))::int)
           WHEN i < interval '1 hour'   THEN format('%sm%ss',
                                              trunc(extract(epoch FROM i)::numeric / 60)::int,
                                              trunc(extract(epoch FROM i)::int)::int % 60)
           ELSE format('%sh%sm', trunc(extract(epoch FROM i)::numeric / 3600)::int,
                                        trunc(extract(epoch FROM i)::numeric / 60)::int % 60)
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_age(interval) IS
  'Compact interval rendering: 4s, 1m30s, 2h05m. Null becomes ''-''.';


-- The conventional abbreviations for the table-level lock modes, so a wide tree does not
-- spend 19 characters per line repeating "AccessExclusiveLock". Advisory and internal
-- locktypes have no standard short form, so they pass through unchanged.
CREATE FUNCTION @extschema@.lock_tree_mode_short(mode text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE mode
           WHEN 'AccessShareLock'           THEN 'AS'
           WHEN 'RowShareLock'              THEN 'RS'
           WHEN 'RowExclusiveLock'          THEN 'RX'
           WHEN 'ShareUpdateExclusiveLock'  THEN 'SUE'
           WHEN 'ShareLock'                 THEN 'S'
           WHEN 'ShareRowExclusiveLock'     THEN 'SRX'
           WHEN 'ExclusiveLock'             THEN 'E'
           WHEN 'AccessExclusiveLock'       THEN 'AX'
           ELSE mode
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_mode_short(text) IS
  'Abbreviate a lock mode (AX for AccessExclusiveLock). Unknown modes pass through.';


CREATE FUNCTION @extschema@.lock_tree_state_short(s text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE s
           WHEN 'idle in transaction (aborted)' THEN 'idle-in-tx (abort)'
           WHEN 'idle in transaction'           THEN 'idle-in-tx'
           ELSE s
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_state_short(text) IS
  'Abbreviate a session state (idle-in-tx for idle in transaction). Other states unchanged.';


-- The one renderer both text functions use. `short` switches on the abbreviations above.
-- The suggestion is deliberately NOT part of a tree line: with dozens of blocked sessions
-- the tree is already wide, and a ready-made command on every line buries the structure.
-- lock_tree_actions() emits those commands separately, once per root.
CREATE FUNCTION @extschema@.lock_tree_lines(query_width int, short boolean)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN depth = 0
           THEN format('%s  %s  %s  %s  %s',
                       pid,
                       CASE WHEN short THEN @extschema@.lock_tree_state_short(state) ELSE state END,
                       @extschema@.lock_tree_age(xact_age),
                       coalesce(nullif(application_name, ''), coalesce(usename, '?')),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
           ELSE format('%s%s  %s  %s  %s  %s',
                       repeat('  ', depth - 1) || '└─',
                       pid,
                       @extschema@.lock_tree_age(wait_age),
                       CASE WHEN short
                            THEN coalesce(@extschema@.lock_tree_mode_short(split_part(waiting_for, ' ', 1)), '?')
                                  || ' ' || coalesce(split_part(waiting_for, ' on ', 2), '')
                            ELSE 'for ' || coalesce(waiting_for, wait_event) END,
                       coalesce(wait_event, '-'),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
         END
  FROM @extschema@.lock_tree
  ORDER BY root_pid, path
$$;


COMMENT ON FUNCTION @extschema@.lock_tree_lines(int, boolean) IS
  'The renderer behind lock_tree_text() and lock_tree_text_short(). Exposed so the width '
  'comparison in scenarios/s4 can attribute the saving to each abbreviation separately.';


CREATE FUNCTION @extschema@.lock_tree_text(query_width int DEFAULT 60)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$ SELECT @extschema@.lock_tree_lines(query_width, false) $$;

COMMENT ON FUNCTION @extschema@.lock_tree_text(int) IS
  'The lock tree as indented text lines, for reading in psql. Full unabbreviated names.';


CREATE FUNCTION @extschema@.lock_tree_text_short(query_width int DEFAULT 100)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$ SELECT @extschema@.lock_tree_lines(query_width, true) $$;

COMMENT ON FUNCTION @extschema@.lock_tree_text_short(int) IS
  'As lock_tree_text(), but with abbreviated lock modes (AX), session states (idle-in-tx) '
  'and compact intervals (1m30s). Meant for a wide queue where every column counts; the '
  'default query_width is larger because the abbreviations gave the room back.';


--------------------------------------------------------------------------------
-- actions, on their own lines
--------------------------------------------------------------------------------

-- Deliberately separate from the tree. When a hundred sessions are stuck, the tree is
-- already a wall of text; interleaving a command per line would double it and make the
-- structure harder to read. This returns a small block, one ready-to-paste command per
-- root, ordered by how much each one unblocks.
--
-- It is SETOF text rather than a table so it can be read straight through psql, and it
-- carries the pid, the reason and the blast radius on the same line as the command,
-- because an operator about to terminate a session needs that context in front of them.
CREATE FUNCTION @extschema@.lock_tree_actions()
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  WITH r AS (
    SELECT root_pid, state, blocked_sessions, max_depth, longest_wait
    FROM @extschema@.lock_tree_roots()
  ), numbered AS (
    SELECT row_number() OVER (ORDER BY blocked_sessions DESC, root_pid) AS n, r.*
    FROM r
  ), lines AS (
    -- sort 0 = header, 1..n = the commands, 2 = footer, so the block reads top to bottom.
    -- The column is named `body` throughout: `line` is a reserved word in SQL and cannot be
    -- used as a column alias here.
    SELECT 0 AS ord, 0 AS seq,
           format('-- %s root blocker(s). Most sessions unblocked first.', count(*)) AS body
    FROM numbered
    UNION ALL
    SELECT 1, n,
           format('-- %s. %s%s%s%s',
                  n,
                  CASE WHEN state LIKE 'idle in transaction%'
                       THEN format('idle in an open transaction; pg_terminate_backend(%s);', root_pid)
                       ELSE format('try pg_cancel_backend(%s) first;', root_pid) END,
                  format('  blocks %s session(s)', blocked_sessions),
                  format(', chain depth %s', max_depth),
                  CASE WHEN longest_wait IS NOT NULL
                       THEN format(', longest wait %s', @extschema@.lock_tree_age(longest_wait))
                       ELSE '' END)
    FROM numbered
    UNION ALL
    SELECT 2, 0,
           '-- Terminating a session rolls back its transaction. Re-run the tree afterwards.'
    WHERE EXISTS (SELECT 1 FROM numbered)
  ), filtered AS (
    -- No output row may be NULL: psql renders NULL as an empty line, which would put gaps in
    -- the middle of the block. Only the first header row survives.
    SELECT row_number() OVER (ORDER BY ord, seq) AS final,
           CASE WHEN ord = 0 AND row_number() OVER (ORDER BY ord, seq) > 1
                THEN NULL ELSE body END AS body
    FROM lines
  )
  SELECT coalesce(body, '')
  FROM filtered
  WHERE body IS NOT NULL
  ORDER BY final
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_actions() IS
  'One copy-and-paste command per root blocker, ordered by sessions unblocked, each with '
  'its blast radius. Kept separate from the tree so a wide queue stays readable.';