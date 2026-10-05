/* pg_lock_tree--0.15--0.16.sql
 *
 * An index chosen by measurement, query_id on the live view, and no behaviour change anywhere.
 *
 *   lock_tree_history_application_idx   new index, partial on the root rows
 *   lock_tree                            CREATE OR REPLACE VIEW, one column appended
 *
 * THE INDEX. Three candidates were tried against the same seven day 1.2 million row fixture and only
 * one kept. Whole-window lock_tree_duration() and lock_tree_duration_by_application():
 *
 *   no extra index                                    2000 ms   2634 ms
 *   (application_name, sampled_at) WHERE depth = 0     1651 ms   2002 ms   1888 kB
 *   (sampled_at)            WHERE depth = 0            1750 ms   2214 ms   1344 kB
 *   (root_pid, sampled_at)  WHERE depth > 0            1701 ms   2501 ms   9744 kB
 *
 * The write path was measured too, since lock_tree_sample() inserts a row per blocked session: one
 * sample of 20 rows took 0.8 ms without the index and 0.7 ms with it, which is noise, because the
 * partial predicate puts one entry per sample in it rather than twenty.
 *
 * WHY A NEW INDEX AT ALL, GIVEN 0.15. 0.15 turned the window bound into an Index Cond, which took the
 * one hour window to 12 ms and made the whole-window read the only slow path left. This is what
 * helps that one.
 *
 * query_id ON THE VIEW. Appending is the only change CREATE OR REPLACE VIEW permits to a view, and
 * that is exactly what this is. Without it the live tree could not be joined to lock_tree_history on
 * the column both are keyed by.
 *
 * CREATE INDEX inside an update script is safe on this table for one reason worth stating: it takes
 * a SHARE lock, which permits reads and blocks writes for the duration. On a table a sampler writes
 * to, that is a pause of the build, not a rebuild. It is not CONCURRENTLY, because that cannot run
 * inside a transaction block and an update script is one. On a large history, run CREATE INDEX
 * CONCURRENTLY by hand instead and accept that the index is then not managed by the extension.
 */

CREATE OR REPLACE VIEW @extschema@.lock_tree AS
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
         -- Appended in 0.16 so the final SELECT can carry it. pg_stat_activity has carried query_id
         -- since PostgreSQL 14, which is this extension's floor, so there is no version guard to
         -- write here and therefore none.
         a.query_id,
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
       p.root_object,
      -- Appended in 0.16, and for the same reason as root_object: appending is the only change a
      -- view may make to itself, since CREATE OR REPLACE VIEW cannot drop or reorder a column.
      --
      -- Without it the live tree cannot be joined to lock_tree_history on query_id, and query_id is
      -- what the whole duration family is keyed on, so the two halves of the extension could not be
      -- tied together in one query. lock_tree_replay() has carried this since 0.14 and its changelog
      -- entry noted the asymmetry rather than fixing it.
      --
      -- NULL for a waiter, always, and that is not an omission: a query blocked on a lock has no
      -- query_id for as long as it is blocked and only gains one when it completes. The root is the
      -- opposite and always has one. Same rule the history follows, so the two line up.
       a.query_id
FROM placed p
LEFT JOIN act a   ON a.pid = p.pid
LEFT JOIN waiting w ON w.pid = p.pid
ORDER BY p.root_pid, p.root_object NULLS FIRST, p.path;

COMMENT ON VIEW @extschema@.lock_tree IS
  'Sessions in lock-wait chains. depth 0 = root blocker; path = chain from the root. '
  'Names are unabbreviated; see lock_tree_text_short() for a compact rendering. '
  'Needs pg_read_all_stats (or superuser) to see other users'' queries.';

CREATE INDEX lock_tree_history_application_idx
  ON @extschema@.lock_tree_history (application_name, sampled_at)
  WHERE depth = 0;
