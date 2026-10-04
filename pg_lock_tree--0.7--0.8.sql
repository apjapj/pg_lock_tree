/* pg_lock_tree--0.7--0.8.sql
 *
 * A bug fix, not a feature, and the bug was in the view rather than in something built on top of
 * it.
 *
 * Two prepared transactions blocking two different objects were reported as ONE root. Not as two
 * rows, and not as two roots in one row: as a single root_pid 0 whose blocked_sessions was the sum
 * of two blockers each holding half as much. lock_tree_summary() said roots = 1. So the number an
 * operator would act on was wrong, in the one case this extension is proudest of, since the
 * published recursive CTE cannot report a prepared transaction at all.
 *
 * The cause is not subtle once stated: pg_blocking_pids() reports the blocker as 0 for every
 * prepared transaction, because a prepared transaction has no backend. Every prepared root was
 * therefore pid 0, and everything that grouped on the pid merged them.
 *
 * What this adds:
 *
 *   lock_tree.root_object            what a prepared root is holding; NULL for a session root,
 *                                    whose pid already identifies it
 *   lock_tree_history.root_object    the same, recorded by lock_tree_sample()
 *   lock_tree_alert.root_object      the same, and now part of the primary key
 *
 * lock_tree_roots(), lock_tree_wide(), lock_tree_statements() and lock_tree_incidents() gain a
 * column; it sits immediately after root_pid rather than at the end, because the two are one
 * identity and separating them by eight columns is how a reader ends up believing pid alone is
 * enough.
 *
 * Three mechanical notes, all verified rather than assumed:
 *
 *   CREATE OR REPLACE VIEW appends columns but cannot drop or reorder them, which is why
 *   root_object goes last on the view and second everywhere else. The view's seventeen existing
 *   columns keep their names, types and positions.
 *
 *   CREATE OR REPLACE FUNCTION refuses a changed OUT list outright: "cannot change return type of
 *   existing function". So the four functions that gained a column are dropped and recreated.
 *   DROP FUNCTION of an extension member inside an update script is allowed, and the replacement
 *   is re-added as a member automatically, so no ALTER EXTENSION ... DROP is needed.
 *
 *   Both ADD COLUMNs are metadata-only, with no table rewrite and no rewrite lock: the history one
 *   has no default at all, and the alert one has DEFAULT '' because it joins a NOT NULL primary
 *   key and existing rows have no value for it. An empty string is the honest answer, since the
 *   value was never captured and every existing row is a session root whose pid identifies it.
 */

--------------------------------------------------------------------------------
-- the view
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- the tables
--------------------------------------------------------------------------------

-- No default and no NOT NULL: existing rows get NULL, which is correct, because a row sampled
-- before this upgrade has no recorded object and inventing one would be a guess.
ALTER TABLE @extschema@.lock_tree_history ADD COLUMN IF NOT EXISTS root_object text;

-- DEFAULT '' rather than no default, because this column joins a NOT NULL primary key and the
-- ALTER cannot leave existing rows NULL. Still metadata-only: a non-volatile DEFAULT is not
-- evaluated per row at 11 and later.
ALTER TABLE @extschema@.lock_tree_alert ADD COLUMN IF NOT EXISTS root_object text NOT NULL DEFAULT '';

-- The primary key is what actually broke. Every prepared transaction is pid 0, so one row held the
-- state of all of them and their wait counts were compared against each other: neither prepared
-- root escalated on its own, because the other one's sessions were already the recorded high
-- water mark.
ALTER TABLE @extschema@.lock_tree_alert DROP CONSTRAINT IF EXISTS lock_tree_alert_pkey;
ALTER TABLE @extschema@.lock_tree_alert
  ADD CONSTRAINT lock_tree_alert_pkey PRIMARY KEY (channel, policy, root_pid, root_object);

--------------------------------------------------------------------------------
-- functions whose body changed but whose signature did not
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_lines(query_width int, short boolean)
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

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_sample()
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

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_notify(
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

--------------------------------------------------------------------------------
-- functions that gained a column, so they are dropped and recreated
--------------------------------------------------------------------------------

DROP FUNCTION @extschema@.lock_tree_roots();

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

DROP FUNCTION @extschema@.lock_tree_wide();

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

DROP FUNCTION @extschema@.lock_tree_statements();

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

DROP FUNCTION @extschema@.lock_tree_incidents(interval);

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
