/* pg_lock_tree--0.6--0.7.sql
 *
 * One new function, and lock_tree_history gains two columns and an index. The columns are added
 * with ALTER TABLE ... ADD COLUMN, which is a metadata-only change: no rows are rewritten and no
 * rewrite lock is taken, so this applies instantly whatever the size of the history.
 *
 *   lock_tree_history.query_id           the root's pg_stat_statements query_id, NULL on waiters
 *   lock_tree_history_statements()      per-query blocking time, worst first
 *
 * Nothing else changes. Every function from 0.6 keeps its signature and its output, so there is
 * nothing to migrate beyond the new columns.
 */

-- The two new columns. ADD COLUMN with no DEFAULT is metadata-only on PostgreSQL 11 and later,
-- so existing rows are untouched and readable with NULL in the new columns, which is correct:
-- samples taken before this upgrade have no query_id recorded and cannot be asked for one.
ALTER TABLE @extschema@.lock_tree_history ADD COLUMN IF NOT EXISTS query_id bigint;

-- Partial, because query_id is NULL for every waiter row and an index over mostly-NULL keys is
-- mostly wasted space. Per-query accounting reads by query_id over a time range, which this serves
-- directly.
CREATE INDEX IF NOT EXISTS lock_tree_history_query_id_idx
  ON @extschema@.lock_tree_history (query_id, sampled_at DESC)
  WHERE query_id IS NOT NULL;

COMMENT ON COLUMN @extschema@.lock_tree_history.query_id IS
  'The root''s pg_stat_statements query_id, NULL on waiter rows. A query blocked on a lock has no '
  'query_id until it completes, so only roots carry one; see lock_tree_history_statements().';

-- The sample function itself changes, so that new samples record the root's query_id. Rows taken
-- before this upgrade keep a NULL there and are not backfilled: the value was never captured, and
-- inventing one from the stored query text would produce a queryid that does not match anything
-- in pg_stat_statements.
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
       wait_age, application_name, query, query_id)
    SELECT statement_timestamp(), lt.root_pid, lt.depth, lt.pid, lt.state, lt.waiting_for,
           lt.wait_age, lt.application_name, left(coalesce(lt.query, ''), 300),
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
