/* pg_lock_tree--0.4.sql
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
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 0.4 adds history. Every other object here reports the present, which is the one thing this
 * extension cannot do at the moment you need it: explain an incident that has already
 * cleared. The view and every function from 0.3 are unchanged, columns and all, so nothing
 * that greps on 'AccessExclusiveLock' or selects from lock_tree is affected.
 *
 * History is opt-in and stays empty until you schedule lock_tree_sample(). Nothing here runs
 * by itself, and the extension still needs no shared_preload_libraries: pg_cron is one
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
