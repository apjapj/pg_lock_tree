/* pg_lock_tree--0.3.sql
 *
 * Readable lock-wait trees for PostgreSQL 14+.
 *   lock_tree              view: every session in a blocking chain, root first
 *   lock_tree_roots()      the head-of-line blockers, with how many sessions wait on each
 *   lock_tree_text()       the same tree as indented text, for psql during an incident
 *   lock_tree_text_short() the same, with abbreviations, for when the queue is wide
 *   lock_tree_actions()    a written description of each blocker, with its blast radius
 *   lock_tree_command()    one runnable statement per blocker, for psql's \gexec
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 0.3 splits the action block in two. 0.2 put a command fragment inside a SQL comment, which
 * read like something you could paste and was not: pasting the whole line did nothing at all,
 * silently, and pasting only the fragment was a syntax error. The description now lives in
 * lock_tree_actions() and carries no imitation code, while lock_tree_command() returns only
 * statements that actually execute. The view's columns and values are unchanged and still
 * carry the full, unabbreviated names, so nothing that greps on 'AccessExclusiveLock' breaks.
 */

\echo Use "CREATE EXTENSION pg_lock_tree" to load this file. \quit

DO $check$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    -- Stated at the length someone hitting it will actually want, because "unsupported" on
    -- its own tells them nothing about whether it is worth patching.
    RAISE EXCEPTION
      'pg_lock_tree needs PostgreSQL 14 or later. It reports wait age from pg_locks.waitstart, '
      'which PostgreSQL added in 14; every other query here works on 9.6 and later, so on an '
      'older server this would run with wait_age and longest_wait reporting NULL. This build '
      'refuses rather than handing back columns that are quietly empty.';
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
           -- pid 0 is a prepared transaction. It has no backend, so cancel and terminate are
           -- both no-ops on it: pg_cancel_backend(0) returns false and warns that PID 0 is
           -- not a PostgreSQL backend process. The only thing that clears it is ROLLBACK
           -- PREPARED, and the gid is not reachable from here, so name the catalog instead.
           WHEN r.pid = 0
             THEN 'Prepared transaction: it has no backend, so cancelling or terminating it '
                  || 'does nothing. Run SELECT gid FROM pg_prepared_xacts, then '
                  || 'ROLLBACK PREPARED ''<gid>''.'
           -- Never hand the operator a command that kills the session they are typing in.
           WHEN r.pid = pg_backend_pid()
             THEN 'This is your own session, so there is nothing to terminate. Re-run from '
                  || 'another connection.'
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
-- actions: a description, and separately the statements to run
--------------------------------------------------------------------------------

-- Two functions, one job each, and deliberately not combined.
--
-- 0.2 returned a single block that carried a command fragment inside a SQL comment. That was
-- a false promise in both directions: every line began with "--", so pasting a line did
-- nothing at all and still exited 0, while extracting just the fragment gave
-- "syntax error at or near pg_terminate_backend", because a bare function call is not a
-- statement. A trailing semicolon told the reader the line was runnable when it was inert.
--
-- The fix is not to add "SELECT" and make the block executable. A block of real statements
-- means a paste runs every root at once, unreviewed, which is the accident this was avoiding
-- in the first place. So: description here, statements over there, and nothing that looks like
-- one while being the other.

-- The description. Never imitates code, so a semicolon here would be a lie about runnability.
-- SET lock_tree.actions = off turns the whole thing off for a session, for anyone who reads
-- the tree and wants the roots as columns (lock_tree_roots()) rather than as prose. This is a
-- placeholder GUC: a pure-SQL extension can read and test one without declaring it, and
-- current_setting() returns NULL until something sets it. RESET leaves an empty string
-- rather than NULL, hence the nullif().
CREATE FUNCTION @extschema@.lock_tree_actions()
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  WITH r AS (
    SELECT root_pid, state, application_name, usename,
           blocked_sessions, max_depth, longest_wait
    FROM @extschema@.lock_tree_roots()
  ), numbered AS (
    SELECT row_number() OVER (ORDER BY blocked_sessions DESC, root_pid) AS n, r.*
    FROM r
  ), lines AS (
    -- sort 0 = header, 1..n = one description per root, 2..3 = footer, so it reads top to
    -- bottom. The column is named `body` throughout: `line` is a reserved word in SQL and
    -- cannot be used as a column alias here.
    SELECT 0 AS ord, 0 AS seq,
           format('-- %s root blocker(s). Most sessions unblocked first.', count(*)) AS body
    FROM numbered
    UNION ALL
    SELECT 1, n,
           format('-- %s. %s: %s, blocks %s session(s), chain depth %s%s',
                  n,
                  coalesce(nullif(application_name, ''),
                           coalesce(nullif(usename, ''), 'pid ' || root_pid)),
                  CASE WHEN root_pid = 0
                       THEN 'prepared transaction, no backend to act on'
                       ELSE state END,
                  blocked_sessions,
                  max_depth,
                  CASE WHEN longest_wait IS NOT NULL
                       THEN format(', longest wait %s', @extschema@.lock_tree_age(longest_wait))
                       ELSE '' END)
    FROM numbered
    UNION ALL
    SELECT 2, 0,
           '-- Descriptions, not commands. Every line here is a comment. For statements you '
           || 'can run: SELECT command FROM lock_tree_command().'
    WHERE EXISTS (SELECT 1 FROM numbered)
    UNION ALL
    SELECT 3, 0,
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
    AND lower(coalesce(nullif(current_setting('lock_tree.actions', true), ''), 'on'))
        NOT IN ('off', 'false', 'no', '0')
  ORDER BY final
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_actions() IS
  'A written description of each root blocker and its blast radius, ordered by how many '
  'sessions each one unblocks. Every line is a SQL comment: this describes, it does not run. '
  'Use lock_tree_command() for statements you can execute. SET lock_tree.actions = off '
  'suppresses it entirely, for anyone who prefers the columns in lock_tree_roots().';


-- The statements. One column, one runnable statement per row, no prose and no comments, so it
-- is equally usable four ways: read it and type one line, hand it to \gexec, \copy it to a
-- file, or feed it to another tool.
--
-- Always the least destructive step that can work. An idle-in-transaction blocker is not doing
-- anything a cancel could interrupt, so cancelling it would achieve nothing and terminate is
-- the real remedy. Anything else gets pg_cancel_backend() first, and promoting that to a
-- terminate stays a decision the operator makes, with lock_tree_roots() spelling out both.
--
-- Two kinds of root produce no row, on purpose:
--   pid 0, a prepared transaction. It has no backend to act on, and the statement that would
--     clear it (ROLLBACK PREPARED) needs a gid this extension cannot see. Silently emitting
--     pg_cancel_backend(0) would look like a fix and do nothing.
--   your own pid. An operator must not be handed the means to disconnect themselves mid-query.
-- lock_tree_roots() covers both cases in suggested_action, and lock_tree_actions() says so.
CREATE FUNCTION @extschema@.lock_tree_command()
RETURNS TABLE (command text)
LANGUAGE sql STABLE
AS $$
  SELECT format('SELECT %s(%s);',
                CASE WHEN state LIKE 'idle in transaction%'
                     THEN 'pg_terminate_backend' ELSE 'pg_cancel_backend' END,
                root_pid)
  FROM @extschema@.lock_tree_roots()
  WHERE root_pid <> 0
    AND root_pid <> pg_backend_pid()
  ORDER BY blocked_sessions DESC, root_pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_command() IS
  'One executable statement per root blocker, ordered by how many sessions each unblocks: '
  'pg_terminate_backend() for an idle-in-transaction blocker, pg_cancel_backend() for anything '
  'else. Intended for psql: SELECT command FROM lock_tree_command() \gexec. Excludes '
  'prepared transactions, which have no backend, and your own session.';
