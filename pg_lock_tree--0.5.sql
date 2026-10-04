/* pg_lock_tree--0.5.sql
 *
 * Readable lock-wait trees for PostgreSQL 14+.
 *   lock_tree              view: every session in a blocking chain, root first
 *   lock_tree_roots()      the head-of-line blockers, with how many sessions wait on each
 *   lock_tree_text()       the same tree as indented text, for psql during an incident
 *   lock_tree_text_short() the same, with abbreviations, for when the queue is wide
 *   lock_tree_actions()    a written description of each blocker, with its blast radius
 *   lock_tree_command()    one runnable statement per blocker, for psql's \gexec
 *   lock_tree_history      table: sampled snapshots, for incidents that have already cleared
 *   lock_tree_sample()     take one snapshot. Call this on a schedule.
 *   lock_tree_incidents()  segment the history into incidents
 *   lock_tree_prune()      drop history older than a given age
 *   lock_tree_wide()       one row per root, for when the tree itself is too wide to read
 *   lock_tree_summary()    one row for the whole queue: sessions blocked, roots, deepest chain
 *   lock_tree_statements() per root: what pg_stat_statements knows about the blocking query
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 0.5 adds the wide case and the pg_stat_statements join. Everything from 0.4 is unchanged,
 * columns and all.
 *
 * lock_tree_text_short() made a wide queue narrower by abbreviating. That helps at sixty
 * sessions and stops helping at six hundred: the shape is still sixty or six hundred lines,
 * and the question "which of my five blockers is the worst one" still needs every line
 * read to be answered. lock_tree_wide() aggregates to one row per root instead, and
 * lock_tree_summary() to a single row for the whole queue.
 *
 * History remains opt-in and stays empty until you schedule lock_tree_sample(). Nothing here
 * runs by itself, and the extension still needs no shared_preload_libraries: pg_cron is one
 * convenient way to schedule the sample, not a requirement of it.
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


--------------------------------------------------------------------------------
-- history: what the tree looked like while you were not looking
--------------------------------------------------------------------------------

-- Everything above describes the present. That is a real limit: an incident is usually
-- discovered after it has ended, by a slow query, a timeout, or a user reporting that
-- "it was hanging earlier". By then pg_stat_activity has moved on and the tree is empty.
-- This is the part that closes that gap: sample on a schedule, keep it, and segment the
-- result into incidents you can read later.
--
-- Nothing here runs by itself. lock_tree_sample() takes exactly one snapshot and is the
-- only thing that writes. Until you schedule it, the table stays empty and this extension
-- behaves exactly as 0.3 did.
--
-- The extension still needs no shared_preload_libraries. pg_cron is a convenient scheduler
-- and nothing more: any scheduler works, including a cron job on the database host calling
-- psql. If you do use pg_cron, see INSTALL.md, because it needs preloading and that is a
-- server change rather than an extension one.

-- sampled_at is statement_timestamp(), and getting that right took two attempts worth
-- recording. clock_timestamp() is volatile and is therefore evaluated once per ROW, so the
-- two sessions in a two-session chain landed microseconds apart. Grouping by sampled_at
-- then yields one group per session instead of one per sample, which silently reduces
-- peak_sessions to 1 for every incident ever recorded. now() has the opposite problem: it
-- is the transaction timestamp, so every row across every sample in one transaction shares
-- an instant and the whole thing collapses to one point. statement_timestamp() is stable
-- for the duration of the one statement that takes the sample, and moves between samples,
-- which is exactly the grain the grouping below needs.
--
-- The table holds one row per session per sample, not one row per sample: the shape of the
-- chain is the thing worth keeping, and a single row per sample would throw away depth,
-- path and wait age. query is truncated to 300 characters because the history of a wide
-- queue is mostly the same few long queries repeated, and unbounded text turns a sampling
-- table into a disk problem.
CREATE TABLE @extschema@.lock_tree_history (
  sampled_at       timestamptz NOT NULL,
  root_pid         int         NOT NULL,   -- 0 for a prepared transaction
  depth            int         NOT NULL,
  pid              int         NOT NULL,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text
);

-- One index for the common question, "what happened between 09:00 and 10:00", and one for
-- "what has this session been doing", which is how you find the pid that caused the whole
-- thing after it has gone. Both are created here rather than left to the user: an
-- unindexed history table is one nobody can afford to query once it has a day of samples.
CREATE INDEX lock_tree_history_sampled_at_idx
  ON @extschema@.lock_tree_history (sampled_at);
CREATE INDEX lock_tree_history_pid_idx
  ON @extschema@.lock_tree_history (pid, sampled_at DESC);

COMMENT ON TABLE @extschema@.lock_tree_history IS
  'Sampled lock-wait trees, one row per session per sample. Empty until lock_tree_sample() '
  'is scheduled. Prune it with lock_tree_prune(); it grows by (sessions blocked) rows per sample.';


-- Take one snapshot. Returns how many rows it wrote, which is 0 on a quiet database: this
-- writes nothing rather than a row saying nothing happened, so an idle server costs one
-- cheap SELECT and no storage at all.
--
-- SECURITY DEFINER so the scheduled job's role needs no INSERT grant on the table. It is a
-- SECURITY DEFINER function that inserts a fixed column list from lock_tree and takes no
-- arguments, so there is nothing for a caller to steer.
CREATE FUNCTION @extschema@.lock_tree_sample()
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  -- The CTE is what makes the return type work. A bare INSERT cannot be the body of a
  -- function returning bigint: SQL requires INSERT ... RETURNING, and RETURNING on a
  -- snapshot of a quiet database yields no rows at all, so the function would return zero
  -- rows rather than 0. Counting inside the CTE gives a row with 0 in it.
  --
  -- search_path is pinned because an unqualified table name cannot resolve under
  -- pg_catalog alone, so @extschema@.lock_tree_history below is qualified explicitly. Both
  -- details were found by trying it rather than by reasoning about it.
  WITH written AS (
    INSERT INTO @extschema@.lock_tree_history
      (sampled_at, root_pid, depth, pid, state, waiting_for,
       wait_age, application_name, query)
    SELECT statement_timestamp(), root_pid, depth, pid, state, waiting_for,
           wait_age, application_name, left(coalesce(query, ''), 300)
    FROM @extschema@.lock_tree
    RETURNING 1
  )
  SELECT count(*) FROM written
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sample() IS
  'Take one snapshot of the current lock tree into lock_tree_history. Returns the number of '
  'rows written, which is 0 when nothing is blocked. Schedule it; nothing calls it for you.';


-- Drop history older than a given age, returning how many rows went.
--
-- This exists because the table grows without bound otherwise: rows are only ever added,
-- and a wide queue at one sample a minute is 60 rows a minute for every session in it.
-- Pruning is a policy choice, so it is a parameter and not a scheduled job. A sensible
-- starting point is a day, or a week if you are chasing a rare one.
--
-- DELETE rather than TRUNCATE because TRUNCATE would take the whole table including rows
-- you wanted to keep.
CREATE FUNCTION @extschema@.lock_tree_prune(older_than interval)
RETURNS bigint
LANGUAGE sql
AS $$
  -- RETURNING 1 for the same reason as above: without it the CTE cannot be counted.
  WITH gone AS (
    DELETE FROM @extschema@.lock_tree_history
    WHERE sampled_at < clock_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM gone
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune(interval) IS
  'Delete lock_tree_history rows older than the given age; returns how many. Call it on the '
  'same schedule as the sample. The table grows by one row per blocked session per sample '
  'otherwise, with nothing to stop it.';


-- The question this whole section exists to answer: "it was hanging earlier, what was it?"
--
-- An incident is a run of samples with no gap longer than max_gap between them. The default
-- of five minutes suits a sample every ten seconds or so, and is a parameter because the
-- right answer depends on how often you sample: too small and one incident splits into
-- several, too large and two incidents merge into one.
--
-- peak_sessions is the high-water mark of sessions blocked at any sample, not the sum, since
-- a session counted at four samples was not four sessions.
CREATE FUNCTION @extschema@.lock_tree_incidents(max_gap interval DEFAULT interval '5 minutes')
RETURNS TABLE (
  incident      bigint,
  started_at    timestamptz,
  ended_at      timestamptz,
  samples       bigint,
  peak_sessions bigint,
  peak_depth    int,
  longest_wait  interval,
  roots         int[],
  applications  text[]
)
LANGUAGE sql STABLE
AS $$
  -- Collapse the per-session rows to one row per sample first, so "how many sessions were
  -- blocked at 14:20" is stored rather than re-derived by counting rows per timestamp in
  -- the outer aggregate.
  WITH per_sample AS (
    SELECT sampled_at,
           count(*)::bigint AS sessions,
           max(depth)::int  AS depth,
           max(wait_age)    AS wait_age
    FROM @extschema@.lock_tree_history
    GROUP BY sampled_at
  ),
  stamped AS (
    SELECT ps.*,
           lag(sampled_at) OVER (ORDER BY sampled_at) AS prev
    FROM per_sample ps
  ),
  marked AS (
    SELECT s.*,
           -- A running sum of "a gap this big starts a new incident", so each sample is
           -- labelled with the incident it belongs to and the labels are then grouped.
           sum(CASE WHEN prev IS NULL OR sampled_at - prev > max_gap THEN 1 ELSE 0 END)
             OVER (ORDER BY sampled_at) AS incident
    FROM stamped s
  )
  SELECT m.incident::bigint,
         min(m.sampled_at),
         max(m.sampled_at),
         count(*)::bigint,
         max(m.sessions)::bigint,
         max(m.depth)::int,
         max(m.wait_age),
         -- Roots and applications are per-session facts, so they come from the raw rows
         -- rather than from per_sample. An array of per-sample arrays is not a shape anyone
         -- wants to read. Scoped to the incident's own time range, and indexed on sampled_at.
         (SELECT array_agg(DISTINCT h.root_pid ORDER BY h.root_pid)
            FROM @extschema@.lock_tree_history h
           WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)),
         (SELECT array_agg(DISTINCT h.application_name ORDER BY h.application_name)
            FROM @extschema@.lock_tree_history h
           WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at))
  FROM marked m
  GROUP BY m.incident
  ORDER BY min(m.sampled_at)
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_incidents(interval) IS
  'The sampled history grouped into incidents: runs of samples with no gap longer than '
  'max_gap (default 5 minutes). For each, when it ran, how many sessions were blocked at '
  'the worst, the deepest chain, the longest wait, and which root pids and application names '
  'were involved. Empty history returns no rows rather than an error.';


--------------------------------------------------------------------------------
-- the wide case: aggregate instead of enumerate
--------------------------------------------------------------------------------

-- A tree of one row per session is the right shape for understanding one incident and the
-- wrong shape for a database with six of them. When sixty sessions are queued behind five
-- roots, the questions an operator actually has are: which root is worst, how many sessions
-- does each one hold up, and is any of them a long chain rather than a flat queue. All three
-- are answerable from one row per root, and none of them require reading sixty lines.
--
-- This is the same aggregate as
--   SELECT root_pid, count(*) FILTER (WHERE depth > 0), max(depth), max(wait_age)
--   FROM lock_tree GROUP BY root_pid
-- given columns, ordering and a text rendering consistent with the rest of the extension.
CREATE FUNCTION @extschema@.lock_tree_wide()
RETURNS TABLE (
  root_pid          int,
  application_name  text,
  state             text,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  wait_events       text[],
  first_waiting_for text
)
LANGUAGE sql STABLE
AS $$
  -- Aggregate over lock_tree directly rather than joining lock_tree to itself: the root row is
  -- already in there at depth 0, and self-joining to find it is the join that goes wrong the
  -- first time someone edits this.
  SELECT t.root_pid,
         max(coalesce(nullif(t.application_name, ''), t.usename)) AS application_name,
         -- Every row of a chain carries the same root, so the root's own state is what the
         -- depth-0 row says. Taking max() over all of them would report a waiter's state, so
         -- read it from the depth-0 row instead.
         max(t.state) FILTER (WHERE t.depth = 0)                  AS state,
         count(*) FILTER (WHERE t.depth > 0)                      AS blocked_sessions,
         max(t.depth)                                              AS max_depth,
         max(t.wait_age)                                           AS longest_wait,
         -- Distinct, because sixty rows of the same wait event is one fact, not sixty.
         array_agg(DISTINCT coalesce(t.wait_event, '?'))          AS wait_events,
         -- What the waiters are after, abbreviated: the mode is the same on all of them in
         -- the common case, and the point here is which lock, not which of forty sessions.
         left(min(coalesce(t.waiting_for, '')) FILTER (WHERE t.waiting_for IS NOT NULL), 60)
                                                                    AS first_waiting_for
  FROM @extschema@.lock_tree t
  GROUP BY t.root_pid
  ORDER BY count(*) FILTER (WHERE t.depth > 0) DESC, max(t.wait_age) DESC NULLS LAST, t.root_pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_wide() IS
  'One row per root blocker instead of one per session: how many sessions each root blocks, '
  'the deepest chain under it, the longest wait, and what they are all waiting for. Use this '
  'rather than lock_tree_text_short() when the queue is wide enough that reading every line '
  'is the problem.';


-- One row for the whole queue. For a dashboard cell, an alert condition, or deciding whether
-- to look at all: is anything blocked, how much, and how bad is the worst of it.
CREATE FUNCTION @extschema@.lock_tree_summary()
RETURNS TABLE (
  blocked_sessions  bigint,
  roots             bigint,
  max_depth         int,
  longest_wait      interval,
  oldest_xact_age   interval
)
LANGUAGE sql STABLE
AS $$
  SELECT count(*) FILTER (WHERE depth > 0),
         count(*) FILTER (WHERE depth = 0),
         coalesce(max(depth), 0),
         max(wait_age),
         -- The oldest open transaction among the roots, which is the number that says "this
         -- has been going for an hour", as distinct from "these have been waiting an hour".
         max(xact_age) FILTER (WHERE depth = 0)
  FROM @extschema@.lock_tree
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_summary() IS
  'One row for the whole lock tree: sessions blocked, roots blocking them, the deepest chain, '
  'the longest wait, and the oldest root transaction. Returns one row of zeros on a quiet '
  'database rather than no rows, so it can be used directly in a dashboard or an alert test.';


--------------------------------------------------------------------------------
-- what pg_stat_statements already knows about the blocking query
--------------------------------------------------------------------------------

-- The other half of lock_tree_wide(): this one says which *kind* of statement is doing the
-- blocking, and what it normally costs, rather than which pid happens to hold the lock this
-- time. Two incidents at 09:00 and at 14:00 have different pids and the same queryid, and it
-- is the queryid that says they are the same problem.
--
-- pg_stat_statements is optional and the function degrades rather than failing. It also needs
-- shared_preload_libraries = pg_stat_statements to be readable at all, and the extension must
-- keep working where it is not loaded, so availability is tested per call rather than assumed.
--
-- One thing this cannot do, found by measuring rather than reasoning: it cannot enrich the
-- WAITERS. A query blocked on a lock has query_id NULL for as long as it is blocked, and only
-- gains one when it completes. So the waiter side of this join is empty during the one moment
-- anybody would want it. The root is the opposite, carrying a query_id throughout. That is
-- fortunate rather than lucky, since the root is the session anyone acts on: knowing the cost
-- of the query holding the lock is the useful half. Stated here because "why is this column
-- null for everything I am blocked on" is otherwise a puzzle.
CREATE FUNCTION @extschema@.lock_tree_statements()
RETURNS TABLE (
  root_pid         int,
  application_name text,
  state            text,
  blocked_sessions bigint,
  query_id         bigint,
  statement        text,
  calls            bigint,
  total_exec_time  double precision,
  mean_exec_time   double precision,
  rows_returned    bigint
)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  -- The join is built as text and run with EXECUTE, which is the only way to reference a
  -- relation that may not exist. A SQL function naming pg_stat_statements directly fails at
  -- CREATE EXTENSION time on a server without it, which would make this optional feature
  -- mandatory. to_regclass decides which query to run; there is no parse to defer here,
  -- because the string is only parsed when executed.
  have_pgss boolean := to_regclass('pg_stat_statements') IS NOT NULL;
BEGIN
  IF NOT have_pgss THEN
    -- No pg_stat_statements loaded: report the roots anyway, with the statement columns empty.
    -- A caller asking "which queries are blocking me" should still learn which roots exist and
    -- how much each one blocks. The feature is missing, not the queue.
    RETURN QUERY
      SELECT w.root_pid, w.application_name, w.state, w.blocked_sessions,
             NULL::bigint, NULL::text, NULL::bigint,
             NULL::double precision, NULL::double precision, NULL::bigint
      FROM @extschema@.lock_tree_wide() w
      ORDER BY w.blocked_sessions DESC, w.root_pid;
    RETURN;
  END IF;

  RETURN QUERY EXECUTE
    'SELECT w.root_pid, w.application_name, w.state, w.blocked_sessions,
            a.query_id,
            left(s.query, 120),
            s.calls,
            s.total_exec_time,
            s.mean_exec_time,
            s.rows
     FROM @extschema@.lock_tree_wide() w
     LEFT JOIN pg_stat_activity a ON a.pid = w.root_pid
     LEFT JOIN pg_stat_statements s ON s.queryid = a.query_id
     ORDER BY w.blocked_sessions DESC, w.root_pid';
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_statements() IS
  'One row per root blocker, joined to pg_stat_statements for the cost of the query holding '
  'the lock: its normalised text, how many times it has run, and its mean and total time. '
  'Groups incidents by query rather than by pid, so the same statement blocking at 09:00 and '
  'at 14:00 is recognisable as one problem. Needs pg_stat_statements in '
  'shared_preload_libraries; without it the statement columns are empty and the roots are '
  'still reported. Cannot enrich waiters: a query blocked on a lock has no query_id until it '
  'completes, so only the blocker side of the join is populated.';
