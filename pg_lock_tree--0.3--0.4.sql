/* pg_lock_tree--0.3--0.4.sql
 *
 * Additive only. 0.4 introduces lock_tree_history plus lock_tree_sample(),
 * lock_tree_prune() and lock_tree_incidents(). Nothing from 0.3 is altered, replaced or
 * dropped: the view's columns, every function's signature, and every rendered string are
 * identical, so there is nothing to migrate and nothing that can break.
 *
 * The history table arrives empty. It stays empty until lock_tree_sample() is scheduled,
 * and nothing in this script schedules it or writes to it.
 */

-- ---------------------------------------------------------------------------------
-- history: what the tree looked like while you were not looking
-- ---------------------------------------------------------------------------------

-- One row per session per sample, so the shape of the chain survives.
--
-- sampled_at is statement_timestamp(), which took two attempts to get right. clock_timestamp()
-- is volatile, so it is evaluated once per ROW and the sessions of one sample landed
-- microseconds apart: grouping by sampled_at then produced one group per session instead of
-- one per sample, silently reducing peak_sessions to 1 in every incident. now() fails the
-- other way, being the transaction timestamp, so everything in one transaction shares an
-- instant. statement_timestamp() is stable for the one statement that takes the sample and
-- moves between samples, which is the grain the grouping below needs.
CREATE TABLE @extschema@.lock_tree_history (
  sampled_at       timestamptz NOT NULL,
  root_pid         int         NOT NULL,
  depth            int         NOT NULL,
  pid              int         NOT NULL,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text
);

CREATE INDEX lock_tree_history_sampled_at_idx
  ON @extschema@.lock_tree_history (sampled_at);
CREATE INDEX lock_tree_history_pid_idx
  ON @extschema@.lock_tree_history (pid, sampled_at DESC);

COMMENT ON TABLE @extschema@.lock_tree_history IS
  'Sampled lock-wait trees, one row per session per sample. Empty until lock_tree_sample() '
  'is scheduled. Prune it with lock_tree_prune(); it grows by (sessions blocked) rows per sample.';


-- SECURITY DEFINER so the scheduled job's role needs no INSERT grant. Takes no arguments
-- and inserts a fixed column list, so a caller has nothing to steer.
--
-- The pinned search_path is why a relation name in the history can be schema-qualified where
-- the same relation read from your session is not: regclass renders with or without the
-- schema depending on whether the schema is in the search path, and this runs with only
-- pg_catalog. Pinning it is the safe choice and the qualification is not a bug, but it is
-- worth knowing before grepping history for a bare table name.
--
-- The data-modifying CTE is required, not stylistic: a bare INSERT cannot be the body of a
-- function returning bigint, because SQL demands INSERT ... RETURNING, and RETURNING on a
-- quiet database yields no rows, so the function would return no rows instead of 0.
-- search_path is pinned and the table is schema-qualified because an unqualified name cannot
-- resolve under pg_catalog alone.
CREATE FUNCTION @extschema@.lock_tree_sample()
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
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


-- The table only ever grows, so something has to delete from it or a wide queue sampled
-- every minute is thousands of rows an hour forever. DELETE and not TRUNCATE, since
-- TRUNCATE would take rows you meant to keep.
CREATE FUNCTION @extschema@.lock_tree_prune(older_than interval)
RETURNS bigint
LANGUAGE sql
AS $$
  -- RETURNING 1 so the CTE can be counted; without it the final SELECT has nothing to read.
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


-- An incident is a run of samples with no gap longer than max_gap. The default suits a
-- sample every ten seconds or so; it is a parameter because the right value depends on the
-- sampling interval. peak_sessions is the high-water mark, not a sum: a session seen at four
-- samples was not four sessions.
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
  -- Collapse to one row per sample first, so the session count is stored rather than
  -- re-derived by counting rows per timestamp in the outer aggregate.
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
           -- Running count of gaps big enough to start a new incident, which labels every
           -- sample with the incident it belongs to.
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
         -- Per-session facts, so read from the raw rows scoped to this incident's own time
         -- range rather than from per_sample: an array of per-sample arrays is unreadable.
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
