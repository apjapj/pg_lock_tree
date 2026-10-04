/* pg_lock_tree--0.8.sql
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
 *   lock_tree_notify()     raise a NOTIFY when a chain is bad enough to be worth waking someone
 *   lock_tree_alert()      table: what has already been alerted on, so it happens once
 *   lock_tree_sampling_advice()  a defensible sampling interval for the current load
 *   lock_tree_history_statements() per-query blocking time, from the sampled history
 *   root_object                what a prepared-transaction root is holding, since pid 0 is not
 *                              enough to tell two of them apart
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 0.8 fixes a real defect in the view itself: two prepared transactions blocking different objects
 * were reported as ONE root, with their wait counts added together, so a single row claimed a
 * blast radius that neither blocker held. Everything from 0.7 is otherwise unchanged, and every
 * existing column keeps its name, type and position. One column is appended at the end of the view
 * and at the end of each function that returns root identity.
 *
 * The cause is that pg_blocking_pids() reports the blocker as 0 for every prepared transaction,
 * because a prepared transaction has no backend. So root_pid was 0 for all of them, and grouping on
 * it merged them. That made the one case this extension is proudest of, the one the published CTE
 * cannot report at all, the one place it got the numbers wrong.
 *
 * Alerting is the missing half of history: history records what happened, but nothing tells
 * anyone it is happening now. lock_tree_notify() raises a NOTIFY on a channel when a chain is
 * bad enough by thresholds you choose, and lock_tree_alert remembers what has been alerted on
 * so the same incident notifies once rather than on every sample.
 *
 * The thresholds are arguments rather than settings, deliberately. A false alarm from a
 * diagnostic tool is worse than no alarm, so the numbers belong to whoever is on call rather than
 * to a default buried in the extension. NULL disables a criterion.
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
prep AS (                       -- what prepared transactions are holding
  -- pg_locks reports a prepared transaction's locks with pid NULL and granted true. That is the
  -- only handle there is on it: there is no gid to join to, and pg_blocking_pids() has already
  -- flattened every prepared blocker to 0. So the lock itself is the identity.
  --
  -- Grouped by the lock OBJECT, locktype plus everything that says which thing is locked, and not
  -- by the mode. Two prepared transactions holding different modes on one relation are one root,
  -- because a waiter wanting an AccessExclusiveLock on it cannot be attributed to either of them
  -- and PostgreSQL itself does not distinguish them. Grouping by mode would report two roots and
  -- count the same waiter against both.
  SELECT min(mode) AS mode, locktype, database, relation, page, tuple,
         classid, objid, objsubid, virtualxid, transactionid
  FROM pg_locks
  WHERE pid IS NULL AND granted
  GROUP BY 2,3,4,5,6,7,8,9,10,11
),
prep_edge AS (                  -- waiters blocked by a prepared transaction, and what they want
  SELECT DISTINCT w.pid AS blocked, p.*
  FROM act a
  JOIN pg_locks w ON w.pid = a.pid AND NOT w.granted
  JOIN prep p
    ON  p.locktype       =  w.locktype
    AND p.database    IS NOT DISTINCT FROM  w.database
    AND p.relation    IS NOT DISTINCT FROM  w.relation
    AND p.page        IS NOT DISTINCT FROM  w.page
    AND p.tuple       IS NOT DISTINCT FROM  w.tuple
    AND p.classid     IS NOT DISTINCT FROM  w.classid
    AND p.objid       IS NOT DISTINCT FROM  w.objid
    AND p.objsubid    IS NOT DISTINCT FROM  w.objsubid
    AND p.virtualxid  IS NOT DISTINCT FROM  w.virtualxid
    AND p.transactionid IS NOT DISTINCT FROM w.transactionid
  WHERE a.blocked_by = ARRAY[0]::int[]
),
edge AS (                       -- one row per (blocked, blocker) pair, with the object if any
  -- A session blocker. The object is NULL because root_pid already identifies it.
  SELECT a.pid AS blocked, b AS blocker, NULL::text AS object
  FROM act a, unnest(a.blocked_by) AS b
  WHERE b <> 0
  UNION ALL
  -- A prepared blocker, attributed to the object it holds.
  -- Always schema-qualified, deliberately. relation::regclass::text would be shorter, but it
  -- qualifies only when the schema is not in the search_path, so the same lock renders as "z1" in
  -- one session and "public.z1" in another. root_object is half of lock_tree_alert's primary key,
  -- and a value that changes with search_path would make an alert fire again for an incident it
  -- had already reported. An identity has to be stable; the cost is one extra word in the output.
  -- waiting_for in this view still uses regclass and is still path dependent, which is cosmetic
  -- there because nothing keys on it.
  SELECT pe.blocked, 0, coalesce(
           CASE
             WHEN pe.relation IS NOT NULL
                  AND pe.database = (SELECT oid FROM pg_database WHERE datname = current_database())
               THEN pe.mode || ' on ' || coalesce(
                      (SELECT n.nspname || '.' || c.relname
                         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE c.oid = pe.relation),
                      pe.relation::text)
             WHEN pe.relation IS NOT NULL
               THEN pe.mode || ' on relation ' || pe.relation || ' in database ' || pe.database
             ELSE pe.mode || ' on ' || pe.locktype
           END, 'a prepared transaction')
  FROM prep_edge pe
  UNION ALL
  -- A waiter blocked by a prepared transaction whose held lock could not be matched: the relation
  -- was dropped, or it belongs to a database whose regclass cannot resolve here. Without this
  -- branch the waiter would have no edge at all and would vanish from the tree, which is a much
  -- worse failure than being reported with a root nobody can tell apart.
  SELECT a.pid, 0, NULL::text
  FROM act a
  WHERE a.blocked_by = ARRAY[0]::int[]
    AND NOT EXISTS (SELECT 1 FROM prep_edge pe WHERE pe.blocked = a.pid)
),
seed AS (                       -- every blocker can head a chain...
  -- DISTINCT over the pair, not the pid. A prepared blocker is (0, <object>), so two prepared
  -- transactions holding different objects are two seeds, which is the whole point of the fix.
  SELECT DISTINCT e.blocker AS pid, e.object
  FROM edge e
),
root AS (                       -- ...but only an unblocked blocker is a real head of the queue;
  SELECT s.pid, s.object        -- pid 0 is not in pg_stat_activity, so a prepared transaction
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
  SELECT s.pid, s.pid AS root_pid, s.object AS root_object, 0 AS depth, ARRAY[s.pid] AS path,
         (r.pid IS NOT NULL) AS rooted
  FROM seed s
  LEFT JOIN root r ON r.pid = s.pid AND r.object IS NOT DISTINCT FROM s.object
  UNION ALL
  SELECT e.blocked, w.root_pid, w.root_object, w.depth + 1, w.path || e.blocked, w.rooted
  FROM walk w
  JOIN edge e ON e.blocker = w.pid
  -- A prepared chain may only pick up the waiters of its own prepared root, matched on the object,
  -- or every prepared chain would pick up every prepared waiter's chain. A session chain takes the
  -- objectless edges, which are all of the session edges.
  WHERE ((w.root_object IS NULL     AND e.object IS NULL)
      OR (w.root_object IS NOT NULL AND e.object = w.root_object))
    AND e.blocked <> ALL (w.path)          -- guard against transient wait-for cycles
),
ranked AS (                    -- rank the chains each session appears in
  SELECT w.*,
         row_number() OVER (PARTITION BY w.pid
                            ORDER BY w.rooted DESC, (w.root_pid = w.pid) DESC,
                                     w.depth DESC, w.path) AS rn
  FROM walk w
),
placed AS (                     -- a waiter can sit behind several blockers: keep its deepest chain
  SELECT pid, root_pid, root_object, depth, path
  FROM ranked
  -- One row per session: a waiter behind several blockers lands in its deepest chain and nowhere
  -- else. The exception is pid 0, which is not a session. Every prepared-transaction root shares
  -- it, because pg_blocking_pids() reports them all as 0, so partitioning on pid alone collapsed
  -- them into whichever sorted first, and the merged root claimed the sum of their wait counts.
  -- That was the bug this column exists to fix, and it was in this line rather than in the walk.
  --
  -- pid 0 only ever appears at depth 0, since edge.blocked comes from pg_stat_activity and those
  -- pids are never 0, so exempting it cannot duplicate a real session.
  WHERE rn = 1 OR pid = 0
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
       a.query,
       -- Appended in 0.8, and NULL for a session root on purpose: root_pid identifies that one
       -- already, and leaving the column NULL there says so rather than padding it. For a
       -- prepared-transaction root this is the lock it is holding, which is the only thing that
       -- tells two of them apart.
       p.root_object
FROM placed p
LEFT JOIN act a   ON a.pid = p.pid
LEFT JOIN waiting w ON w.pid = p.pid
ORDER BY p.root_pid, p.root_object NULLS FIRST, p.path;

COMMENT ON VIEW @extschema@.lock_tree IS
  'Sessions in lock-wait chains. depth 0 = root blocker; path = chain from the root. '
  'Names are unabbreviated; see lock_tree_text_short() for a compact rendering. '
  'Needs pg_read_all_stats (or superuser) to see other users'' queries.';


CREATE FUNCTION @extschema@.lock_tree_roots()
RETURNS TABLE (
  root_pid          int,
  -- Beside root_pid, which is the only place it can go: the two are one identity, and a session
  -- root has this NULL while a prepared-transaction root has the lock it is holding.
  root_object       text,
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
         r.root_object,
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
             THEN 'Prepared transaction holding '
                  || coalesce(r.root_object, 'an unidentified object')
                  || ': it has no backend, so cancelling or terminating it does nothing. Run '
                  || 'SELECT gid FROM pg_prepared_xacts, then ROLLBACK PREPARED ''<gid''.'
           -- Never hand the operator a command that kills the session they are typing in.
           WHEN r.pid = pg_backend_pid()
             THEN 'This is your own session, so there is nothing to terminate. Re-run from '
                  || 'another connection.'
           WHEN r.state LIKE 'idle in transaction%'
             THEN format('Idle in an open transaction. SELECT pg_terminate_backend(%s);', r.pid)
           ELSE format('Try SELECT pg_cancel_backend(%s); then pg_terminate_backend(%s) if it does not clear.',
                       r.pid, r.pid)
         END
  -- Both sides of the join carry root_object, because it is part of the root's identity. Joining
  -- on pid alone put every prepared root against every prepared waiter, so two of them summed
  -- into one row claiming the combined wait count.
  FROM @extschema@.lock_tree r
  JOIN @extschema@.lock_tree t
    ON t.root_pid = r.pid AND t.root_object IS NOT DISTINCT FROM r.root_object
  WHERE r.depth = 0
  GROUP BY r.pid, r.state, r.usename, r.datname, r.application_name,
           r.xact_age, r.state_age, r.query, r.root_object
  ORDER BY count(t.pid) DESC, r.pid, r.root_object
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
           -- A prepared-transaction root is pid 0, which says nothing on its own and repeats on
           -- every prepared root. The object is what distinguishes them, so it goes beside the pid
           -- in parentheses rather than in a column of its own, which would reflow every other
           -- line of the output.
           THEN format('%s%s  %s  %s  %s  %s',
                       pid,
                       CASE WHEN root_object IS NULL THEN ''
                            ELSE format(' (%s)', root_object) END,
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
  query            text,
  -- What a prepared-transaction root is holding. NULL for a session root, because root_pid
  -- identifies that one already. Added in 0.8: two prepared transactions both have root_pid 0, so
  -- without this the history recorded one merged root for two of them.
  root_object      text,
  -- The root's pg_stat_statements query_id, so per-query blocking time can be totalled from the
  -- history. NULL for a root that has no query_id, which includes every waiter row: a query
  -- blocked on a lock has no query_id until it completes. Deliberately NULL rather than
  -- inheriting the root's value, because a waiter and its root running different statements is
  -- the normal case and conflating them would make the totals wrong rather than merely incomplete.
  query_id         bigint
);

-- One index for the common question, "what happened between 09:00 and 10:00", and one for
-- "what has this session been doing", which is how you find the pid that caused the whole
-- thing after it has gone. Both are created here rather than left to the user: an
-- unindexed history table is one nobody can afford to query once it has a day of samples.
CREATE INDEX lock_tree_history_sampled_at_idx
  ON @extschema@.lock_tree_history (sampled_at);
CREATE INDEX lock_tree_history_pid_idx
  ON @extschema@.lock_tree_history (pid, sampled_at DESC);
-- Per-query accounting reads by query_id over a time range, which this index serves directly.
-- Partial, because query_id is NULL for every waiter row and an index over mostly-NULL keys is
-- mostly useless space.
CREATE INDEX lock_tree_history_query_id_idx
  ON @extschema@.lock_tree_history (query_id, sampled_at DESC)
  WHERE query_id IS NOT NULL;

COMMENT ON TABLE @extschema@.lock_tree_history IS
  'Sampled lock-wait trees, one row per session per sample. Empty until lock_tree_sample() '
  'is scheduled. Prune it with lock_tree_prune(); it grows by (sessions blocked) rows per sample. '
  'query_id is the ROOT''s pg_stat_statements query_id and is NULL on waiter rows, since a '
  'blocked query has no query_id until it completes; see lock_tree_history_statements().';


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
       wait_age, application_name, query, root_object, query_id)
    SELECT statement_timestamp(), lt.root_pid, lt.depth, lt.pid, lt.state, lt.waiting_for,
           lt.wait_age, lt.application_name, left(coalesce(lt.query, ''), 300), lt.root_object,
           -- Each row's OWN query_id, which is why the join is on pid rather than on root_pid.
           -- Joining on root_pid propagates the root's query_id down the whole chain, so every
           -- waiter looks like it was running the blocking statement, which is the normal case
           -- and would make the per-query totals wrong rather than merely incomplete.
           --
           -- What this means in practice: a query blocked on a lock has a NULL query_id for as
           -- long as it is blocked, so only depth-0 rows carry one. Same finding as
           -- lock_tree_statements(), and it is why this is per blocking query.
           ra.query_id
    FROM @extschema@.lock_tree lt
    -- A plain left join rather than a LATERAL subquery, because it is hashed once over the
    -- distinct pids instead of being evaluated per row. root_pid 0 is a prepared transaction,
    -- which is in no session at all and so matches nothing, which is correct.
    --
    -- The view is aliased as lt because pg_stat_activity also has a pid column, and with both in
    -- scope every unqualified pid in the select list is ambiguous.
    LEFT JOIN pg_stat_activity ra ON ra.pid = lt.pid
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
  applications  text[],
  -- Added in 0.8. The roots array cannot express two prepared transactions, which are both pid 0,
  -- so it showed one entry for two incidents. This names what each was holding.
  root_objects  text[]
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
           WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)),
         -- Nulls excluded rather than rendered as empty strings: an empty element in this array
         -- would be indistinguishable from a prepared root whose object could not be resolved,
         -- and neither is worth a slot.
         (SELECT array_agg(DISTINCT h.root_object ORDER BY h.root_object)
            FROM @extschema@.lock_tree_history h
           WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)
             AND h.root_object IS NOT NULL)
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
  -- Beside root_pid rather than last, because the two are the root's identity and belong next to
  -- each other: root_pid alone is not enough for a prepared transaction, and a reader who has to
  -- scroll to the end of the row to learn that is the reader who draws the wrong conclusion.
  root_object       text,
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
         t.root_object,
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
  -- Grouped by the pair, not the pid. Two prepared transactions are both pid 0, so grouping on
  -- pid alone merged them and reported one root whose blocked_sessions was the sum of two
  -- blockers each holding half as much. That is the number an operator acts on.
  GROUP BY t.root_pid, t.root_object
  ORDER BY count(*) FILTER (WHERE t.depth > 0) DESC, max(t.wait_age) DESC NULLS LAST,
           t.root_pid, t.root_object
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
  -- counts depth-0 rows, so this depends on the view having exactly one depth-0 row per root.
  -- That held until 0.8, when a prepared root stopped being merged with its peers and started
  -- being one row each: two prepared transactions went from roots = 1 to roots = 2, which is the
  -- correct answer and the reason for the change.
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
  root_object      text,
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
      SELECT w.root_pid, w.root_object, w.application_name, w.state, w.blocked_sessions,
             NULL::bigint, NULL::text, NULL::bigint,
             NULL::double precision, NULL::double precision, NULL::bigint
      FROM @extschema@.lock_tree_wide() w
      ORDER BY w.blocked_sessions DESC, w.root_pid, w.root_object;
    RETURN;
  END IF;

  -- The pg_stat_statements side is aggregated in a LATERAL subquery rather than joined
  -- row-for-row, because queryid is not unique there in practice. Measured on PG 18: one
  -- statement that had run six times sat in two rows, with calls of 1 and 5, and the row-for-row
  -- join produced two output rows for one root. Since this function is documented as one row per
  -- root, and its caller groups incidents by it, a duplicate row is a duplicate incident.
  --
  -- Summing is the right reduction rather than picking a row: the buckets are the same statement,
  -- and the total cost of a statement is what the reader wants. The mean is recomputed from the
  -- sum, not averaged across buckets, because an unweighted mean of means is wrong whenever the
  -- buckets have different call counts, which is the entire reason they are separate.
  RETURN QUERY EXECUTE
    'SELECT w.root_pid, w.root_object, w.application_name, w.state, w.blocked_sessions,
            a.query_id,
            agg.statement,
            agg.calls,
            agg.total_exec_time,
            agg.mean_exec_time,
            agg.rows
     FROM @extschema@.lock_tree_wide() w
     LEFT JOIN pg_stat_activity a ON a.pid = w.root_pid
     LEFT JOIN LATERAL (
       SELECT left(min(s.query), 120) AS statement,
              sum(s.calls)::bigint    AS calls,
              sum(s.total_exec_time) AS total_exec_time,
              sum(s.mean_exec_time * s.calls) / NULLIF(sum(s.calls), 0) AS mean_exec_time,
              max(s.rows)             AS rows
       FROM pg_stat_statements s
       WHERE s.queryid = a.query_id
     ) agg ON true
     ORDER BY w.blocked_sessions DESC, w.root_pid, w.root_object';
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


--------------------------------------------------------------------------------
-- alerting: turning "something is wrong" into "someone was told"
--------------------------------------------------------------------------------

-- Everything so far reports to whoever is already looking. History reports to whoever looks
-- later. Neither tells anyone that something is happening now, which is the moment alerting
-- exists for.
--
-- The design problem is not raising a notification, it is raising the RIGHT number of them. A
-- job that notifies on every sample turns a two-minute incident into twelve notifications and
-- trains everyone to ignore the channel, which is worse than having none: the one alert that
-- mattered gets filtered along with the noise. So lock_tree_notify() notifies on onset and on
-- escalation, and stays quiet while a chain sits at the same severity. lock_tree_alert is what
-- makes that possible.
--
-- NOTIFY rather than anything heavier, deliberately. It needs no extra process, no table to
-- drain, and no polling: any client can LISTEN, and it is transactional, so a rolled-back
-- sample never notifies. The payload is JSON on one channel prefixed with the channel name, so a
-- listener can serve several kinds of alert from one subscription and route on the payload.

-- What has already been alerted on, per channel and per root. Small by construction: one row per
-- root that is currently notable, and rows are removed as soon as the root is gone, so the table
-- holds the size of the current queue rather than its history.
--
-- max_blocked_at and max_depth_at are the high-water marks, not the latest values. That is what
-- makes an escalation distinguishable from a recovery: a root that drops from 40 sessions to 12
-- is getting better and must not re-notify, while one that goes from 12 to 40 is getting worse
-- and must.
CREATE TABLE @extschema@.lock_tree_alert (
  channel          text        NOT NULL,
  policy           text        NOT NULL,
  root_pid         int         NOT NULL,
  -- Part of the primary key from 0.8. It was not in 0.7, and that was a live bug: every prepared
  -- transaction is root_pid 0, so two of them shared one row and their wait counts compared
  -- against each other. NOT NULL with a default so the ALTER below can add it to existing rows
  -- without a rewrite: metadata-only on PostgreSQL 11 and later, and the value was never
  -- captured anyway, so '' is the honest answer rather than NULL.
  root_object      text        NOT NULL DEFAULT '',
  application_name text,
  first_seen       timestamptz NOT NULL,
  last_notified    timestamptz,
  notify_count     int         NOT NULL DEFAULT 0,
  max_blocked_at   bigint      NOT NULL DEFAULT 0,
  max_depth_at     int         NOT NULL DEFAULT 0,
  PRIMARY KEY (channel, policy, root_pid, root_object)
);

CREATE INDEX lock_tree_alert_last_notified_idx
  ON @extschema@.lock_tree_alert (last_notified);

COMMENT ON TABLE @extschema@.lock_tree_alert IS
  'What lock_tree_notify() has already alerted on, per channel, per threshold set, per root. '
  'Rows are removed when the root leaves the tree, so a chain that returns alerts again. The '
  'policy column holds the thresholds the row was written under: two different alerting policies '
  'sharing a channel would otherwise clear each other''s state, and each would re-alert on '
  'every alternate sample. Not history: lock_tree_history is that. Prune with '
  'lock_tree_prune_alerts(). root_object is empty for a session root, whose pid already '
  'identifies it, and names the lock held for a prepared-transaction root.';



-- Notify when a root is notable, and only then. Returns how many notifications were raised,
-- which is the number worth watching: zero on every ordinary sample, one per onset or
-- escalation, and it stays at zero for as long as an incident sits at the same severity.
--
-- Thresholds, and how they combine:
--
--   A root is notable if it meets AT LEAST ONE of the criteria that are set. NULL, or 0 for
--   min_blocked, switches a criterion off. With all three set, a chain alerts if it blocks at
--   least min_blocked sessions, OR is min_deep, OR has anyone waiting min_wait. That is the
--   useful shape: a queue can be bad in ways unrelated to each other, and an operator paging on
--   "deep OR slow" rather than "deep AND slow" will not miss the incident that was both.
--
--   At least one criterion must be set. All three off means "alert on every root", which is not
--   what anyone wants from an alerting function, so it is rejected rather than quietly given a
--   default.
--
-- What this deliberately does not do:
--   - page anything. It raises a NOTIFY on a PostgreSQL channel. Wiring that to a pager is the
--     deployment's business, and the payload is JSON so that whatever it is can parse it.
--   - choose your thresholds. They are arguments. No default is right for everyone, and a
--     default nobody reads is a default nobody trusts.
--   - keep state indefinitely. Rows go when a root does, which is the normal case.
--
-- A row-at-a-time loop rather than nested upserts with a RETURNING clause. The row count is one
-- per root blocker, which is a handful, and the logic here is control flow: compare, decide,
-- write, notify. Written as a loop it reads in the order it happens, and it was the first version
-- that was correct. The alternative spelled the same decision in three nested CTEs and referred
-- to a column that did not exist.
CREATE FUNCTION @extschema@.lock_tree_notify(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,
  min_depth    integer  DEFAULT 2,
  min_wait     interval DEFAULT '30 seconds'
)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  r           record;
  prior       record;
  fired       bigint := 0;
  -- Per-root, not the call's total. Testing `fired > 0` here would mean that once any root had
  -- notified, every later root in the same loop also notified, including ones that should stay
  -- quiet, which is the noise this whole design exists to avoid.
  root_fired  boolean := false;
  -- The thresholds, rendered as one string and used as part of the state key. Two different
  -- alerting policies sharing a channel would otherwise clear each other's state, so each would
  -- re-alert on every alternate sample. Found by a test that alternated thresholds and saw both
  -- roots fire twice where one of them had not actually got worse.
  -- Named pol rather than policy: a plpgsql variable sharing a column's name is ambiguous in
  -- every query that mentions the column, and qualifying it in expressions is not enough,
  -- because there is no valid qualified-assignment form to disambiguate the assignment.
  pol         text;
  -- Normalised thresholds: a criterion set to zero or negative is the same as switching it off,
  -- which is what someone means by passing 0.
  want_blocked integer := CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                               ELSE min_blocked END;
  want_depth   integer := CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                               ELSE min_depth END;
  want_wait    interval := CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                               ELSE min_wait END;
BEGIN
  pol := format('blocked>=%s depth>=%s wait>=%s',
                   coalesce(want_blocked::text, 'off'),
                   coalesce(want_depth::text,   'off'),
                   coalesce(want_wait::text,    'off'));

  IF want_blocked IS NULL AND want_depth IS NULL AND want_wait IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_notify() needs at least one threshold: pass min_blocked, min_depth or '
      'min_wait. Passing NULL switches one criterion off, but all three off means alerting on '
      'every root, which is almost certainly not what you want.';
  END IF;

  FOR r IN
    SELECT w.root_pid, w.root_object, w.application_name, w.blocked_sessions, w.max_depth,
           w.longest_wait, w.first_waiting_for,
           (want_blocked IS NOT NULL AND w.blocked_sessions >= want_blocked)
           OR (want_depth   IS NOT NULL AND w.max_depth       >= want_depth)
           OR (want_wait    IS NOT NULL AND w.longest_wait    >= want_wait) AS notable
    FROM @extschema@.lock_tree_wide() w
  LOOP
    IF NOT r.notable THEN
      -- Below every threshold. It stays below until it stops being in the tree at all, which
      -- the sweep after the loop takes care of, so nothing to do here.
      root_fired := false;
      CONTINUE;
    END IF;

    SELECT * INTO prior FROM @extschema@.lock_tree_alert a
     WHERE a.channel = lock_tree_notify.channel
       AND a.policy  = pol
       AND a.root_pid = r.root_pid
       AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');

    IF NOT FOUND THEN
      -- First time this root has been notable on this channel. That is the onset, and the one
      -- case that is always worth telling someone about.
      INSERT INTO @extschema@.lock_tree_alert
        (channel, policy, root_pid, root_object, application_name, first_seen, last_notified,
         notify_count, max_blocked_at, max_depth_at)
      VALUES (lock_tree_notify.channel, pol, r.root_pid, coalesce(r.root_object, ''),
              r.application_name,
              statement_timestamp(), statement_timestamp(), 1,
              r.blocked_sessions, r.max_depth);
      fired := fired + 1;
      root_fired := true;
    ELSIF r.blocked_sessions > prior.max_blocked_at
       OR r.max_depth > prior.max_depth_at THEN
      -- Escalation. Compared against the high-water marks rather than the previous sample, so a
      -- chain that wobbles between 40 and 12 sessions notifies once, not twice a minute.
      UPDATE @extschema@.lock_tree_alert a
         SET last_notified  = statement_timestamp(),
             notify_count   = notify_count + 1,
             max_blocked_at = greatest(max_blocked_at, r.blocked_sessions),
             max_depth_at   = greatest(max_depth_at, r.max_depth),
             root_object    = coalesce(r.root_object, ''),
             application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
      fired := fired + 1;
      root_fired := true;
    ELSE
      -- Notable but unchanged. Stay quiet: this is the case that turns an alerting function into
      -- noise, and the whole reason lock_tree_alert exists.
      UPDATE @extschema@.lock_tree_alert a
         SET application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
    END IF;

    IF root_fired THEN
      PERFORM pg_notify(lock_tree_notify.channel, json_build_object(
        'channel',           lock_tree_notify.channel,
        'root_pid',          r.root_pid,
        -- null in the payload for a session root, a lock name for a prepared one. A listener
        -- keying on application_name, which is what the documentation recommends, is unaffected;
        -- this is there so a listener that has two prepared roots can tell them apart.
        'root_object',       r.root_object,
        'application_name',  r.application_name,
        'blocked_sessions',  r.blocked_sessions,
        'max_depth',         r.max_depth,
        'longest_wait',      @extschema@.lock_tree_age(r.longest_wait),
        'waiting_for',       r.first_waiting_for
      )::text);
    END IF;
  END LOOP;

  -- Sweep away state for roots that are no longer in the tree at all. This cannot live in the
  -- loop above, because the loop iterates over lock_tree_wide(), and a root whose waiters have
  -- all gone has no edges and therefore no row there: it simply vanishes. Without this sweep the
  -- table grows one row per root ever seen, forever, and every one of them is a pid that will
  -- never be reused. Found by a test asserting the table empties on recovery, which it did not.
  DELETE FROM @extschema@.lock_tree_alert a
   WHERE a.channel = lock_tree_notify.channel
     AND a.policy  = pol
     -- Matched on the pair, not the pid. With the pid alone this sweep deleted a prepared
     -- transaction's state as soon as ANY prepared root was present, because pid 0 matched.
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                      WHERE t.root_pid = a.root_pid
                        AND coalesce(t.root_object, '') = a.root_object);

  RETURN fired;
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_notify(text, integer, integer, interval) IS
  'Raise a NOTIFY on a channel when a root blocker is notable, and remember it so the same '
  'incident notifies once rather than on every sample. A root is notable if it meets AT LEAST '
  'ONE of min_blocked, min_depth or min_wait; NULL or 0 switches one off, and at least one '
  'must be set. Returns how many notifications were raised, so zero is the normal result and '
  'the one worth watching. Payloads are JSON. Wire the channel to a pager yourself: this raises '
  'NOTIFY and nothing more.';


-- Forget alert state that no longer refers to a live session.
--
-- lock_tree_notify() deletes a root's row as soon as that root stops being notable, which is
-- the normal case and needs no help. This is for the abnormal ones: a server that was rebooted
-- mid-incident keeps rows for pids that no longer exist, and a channel name that has been
-- retired keeps rows under it. Small either way, since the table is the size of the current
-- queue, so calling this from the same cron entry as the sample is enough.
CREATE FUNCTION @extschema@.lock_tree_prune_alerts(older_than interval DEFAULT interval '1 day')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH gone AS (
    DELETE FROM @extschema@.lock_tree_alert
    WHERE last_notified IS NOT NULL
      AND last_notified < clock_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM gone
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune_alerts(interval) IS
  'Delete alert state last notified on more than the given age ago; returns how many. Only '
  'needed for alert state orphaned by a restart or a retired channel: lock_tree_notify() '
  'already forgets a root as soon as it stops being notable.';


-- How often to sample, given how busy things currently are.
--
-- The history sample is a cron entry, and a cron entry needs a number. Most people pick one by
-- feel and then either pay for it or miss incidents. The honest answer is that it depends on how
-- wide the queue gets, and this says what that is.
--
-- The reasoning, briefly: a queue changes on the scale of seconds, so a sample interval much
-- above a minute will miss short incidents entirely, while an interval far below a few seconds
-- writes the same state repeatedly and grows the table for nothing. The cost of a sample is one
-- row per blocked session, so the interval that matters is the one that keeps a wide queue from
-- dominating the table.
CREATE FUNCTION @extschema@.lock_tree_sampling_advice()
RETURNS TABLE (
  blocked_sessions bigint,
  roots            bigint,
  suggested_every  interval,
  reason           text
)
LANGUAGE sql STABLE
AS $$
  SELECT s.blocked_sessions,
         s.roots,
         -- Three bands, chosen on cost rather than taste. Under 10 sessions a sample is cheap
         -- and detail is worth having. Under 100 it is 10 times the storage and a 10 second
         -- interval still catches everything that lasts longer than a query. Past that the
         -- table is the dominant cost and 30 seconds is enough to characterise an incident.
         CASE WHEN s.blocked_sessions < 10  THEN interval '5 seconds'
              WHEN s.blocked_sessions < 100 THEN interval '10 seconds'
              ELSE interval '30 seconds' END,
         CASE WHEN s.blocked_sessions = 0
              THEN 'nothing is blocked: the table stays empty at any interval, so sample rarely'
              WHEN s.blocked_sessions < 10
              THEN 'few sessions blocked: cheap to sample finely, so keep the detail'
              WHEN s.blocked_sessions < 100
              THEN 'a busy queue: 10 seconds catches anything that lasts, at a tenth the storage'
              ELSE 'a wide queue: each sample writes a row per blocked session, so widen the interval'
         END
  FROM @extschema@.lock_tree_summary() s
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sampling_advice() IS
  'A suggested interval for lock_tree_sample(), given how many sessions are blocked right now, '
  'and why. The cost of a sample is one row per blocked session, so a wide queue argues for a '
  'wider interval. Empty when nothing is blocked, since then any interval writes nothing.';


--------------------------------------------------------------------------------
-- per-query blocking time
--------------------------------------------------------------------------------

-- The question that gets a fix merged rather than a workaround. lock_tree_statements() answers
-- it for the chain in front of you; this answers it for the month, from samples already taken.
--
-- "Blocking time" rather than "wait time" because it is the number that maps to a fix. A
-- statement that runs for 900ms and holds nothing up is slow. A statement that runs for 40ms and
-- holds sixty sessions up is the one to fix, and only the blocking figure shows that.
--
-- The unit is the session-sample: one blocked session observed at one sample. That is not the
-- same as wall-clock time, and the difference matters. A session blocked for 60 seconds sampled
-- every 10 seconds contributes six, not sixty. This is deliberate and it is a HIGHER bound on
-- precision, not a lower one on importance: it counts each blocked session once per sample in
-- which it was blocked, so shortening the sample interval increases it proportionally and the
-- ranking between statements is stable while the absolute figure is not. last_seen_at and
-- times_seen let you sanity-check which regime a row is in.
--
-- Only roots carry a query_id, so this is per BLOCKING query rather than per blocked query. That
-- is the useful direction: the question is what to fix, and the blocker is what you can change.
CREATE FUNCTION @extschema@.lock_tree_history_statements(
  since interval DEFAULT interval '7 days'
)
RETURNS TABLE (
  query_id         bigint,
  blocked_sessions bigint,
  samples          bigint,
  first_blocked_at timestamptz,
  last_blocked_at  timestamptz,
  deepest_chain    int,
  longest_wait     interval,
  longest_wait_at  timestamptz,
  applications     text[]
)
LANGUAGE sql STABLE
AS $$
  -- No reference to pg_stat_statements here, deliberately. A SQL function naming a relation that
  -- may not exist fails at CREATE EXTENSION time, which is why lock_tree_statements() is plpgsql
  -- with a guarded dynamic query. This one does not need that machinery: the history carries
  -- query_id, and the totals are pure aggregation over a table this extension owns. Joining the
  -- text back in is one line for whoever has the module loaded, shown in the comment below.
  SELECT h.query_id,
         count(*) FILTER (WHERE h.depth = 0)     AS blocked_sessions,
         count(DISTINCT h.sampled_at)              AS samples,
         min(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.depth),
         max(h.wait_age),
         -- When the worst wait was observed, which is what turns "3m12s" into "at 09:14, during
         -- the month-end run". The wait age alone says how bad, not when to go looking.
         (array_agg(h.sampled_at ORDER BY h.wait_age DESC NULLS LAST))[1],
         array_agg(DISTINCT h.application_name ORDER BY h.application_name)
  FROM @extschema@.lock_tree_history h
  WHERE h.query_id IS NOT NULL
    AND h.sampled_at >= clock_timestamp() - since
  GROUP BY h.query_id
  -- Worst first: the statement to fix is at the top, which is the only ordering anyone wants.
  ORDER BY count(*) FILTER (WHERE h.depth = 0) DESC, max(h.wait_age) DESC NULLS LAST
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_history_statements(interval) IS
  'Per-query blocking time from the sampled history, worst first: for each root query id, how '
  'many blocked sessions it held up across all samples, over how many samples, when first and '
  'last seen, the deepest chain and longest wait under it, when that worst wait happened, and '
  'which applications were involved. The figure counts a blocked session once per sample it was '
  'blocked in, so it rises with the sampling rate; the ranking between statements is what to '
  'read. Needs a sampled history: it answers about the past, not about now. To add the statement '
  'text, join pg_stat_statements on query_id yourself; this function does not reference it, so it '
  'works whether or not that module is loaded.';
