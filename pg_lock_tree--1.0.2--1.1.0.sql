/* pg_lock_tree--1.0.2--1.1.0.sql
 *
 * Two changes, both measured before they were written. Neither changes what any function returns
 * for the arguments it already accepted.
 *
 * 1. lock_tree_incidents() takes a window.
 *
 *    It was the only history function that could not be bounded in time, so its cost followed how
 *    much history was retained rather than how much of it was being asked about. Measured at
 *    1.95 microseconds per row as a caller uses it, which is about 1.2 seconds per million rows: a
 *    month of history is roughly 30 seconds, and there was no way to ask it about less.
 *
 *    Two things about the parameter that are easy to get wrong and are both deliberate here.
 *
 *    It goes AFTER max_gap, not before. test/07_history.sql and docs/after-the-incident.md both
 *    call this function positionally, so a new first parameter would reinterpret their argument:
 *    lock_tree_incidents(interval '7 days') would become a window rather than a gap, and would
 *    return one incident per sample rather than the incidents over a week.
 *
 *    Its default is NULL, meaning no bound. A default of interval '7 days' would match its
 *    neighbours and would be wrong: it would compile every existing call site and then quietly
 *    return fewer incidents than it used to on any database holding more than a week. That is a
 *    behaviour change dressed as an additive one, and it is exactly the kind that is invisible in
 *    review and visible in production. NULL means the whole retained history, which is what the
 *    function did in every release before this one.
 *
 *    DROP rather than CREATE OR REPLACE, because PostgreSQL will not let OR REPLACE change a
 *    function's input parameters: that is the function's identity. The COMMENT is reapplied because
 *    dropping the function drops its comment with it.
 *
 * 2. lock_tree_history_application_idx gains INCLUDE (query_id).
 *
 *    lock_tree_duration_by_application() aggregates DISTINCT query_id per application, and without
 *    the column in the index leaf that step is a bitmap heap scan fetching 24,133 pages to answer a
 *    question the index already holds. With it: an Index Only Scan, Heap Fetches 0, 300 buffers, and
 *    117.0 -> 31.2 ms for the step. The whole function goes 2249 -> 2146 ms cold, measured A/B/A/B.
 *
 *    That is a 4% win on a two-second function. It is not the fix for that function and is not
 *    claimed to be; the remaining cost is the aggregation, not the access.
 *
 *    Recreated rather than altered, because PostgreSQL 14, which this extension supports, has no
 *    ALTER INDEX ... ADD INCLUDE. The rebuild is on a 1.9 MB partial index holding one entry per
 *    sample, so it is not a long operation, and it takes a lock that blocks writes to the history
 *    for its duration. On a large history, build the replacement under a different name and swap,
 *    rather than doing this in a transaction with everything else.
 */

-- 2. The index. The function body is below, but the index goes first so that the function is not
--    replaced while a plan built on the old index is still in someone's session.
DROP INDEX @extschema@.lock_tree_history_application_idx;

CREATE INDEX lock_tree_history_application_idx
  ON @extschema@.lock_tree_history (application_name, sampled_at) INCLUDE (query_id)
  WHERE depth = 0;

COMMENT ON INDEX @extschema@.lock_tree_history_application_idx IS
  'Partial index on the root rows, keyed on application_name, for lock_tree_duration_by_application() '
  'and lock_tree_duration(). query_id was INCLUDEd in 1.1.0 so that step can be an Index Only Scan: '
  'measured, it goes 117.0 -> 31.2 ms with Heap Fetches 0, for 528 kB on the 1.9 MB index. Measured '
  'against two alternatives; see the release notes.';

-- 1. The function, whole, because its input parameters changed.
DROP FUNCTION @extschema@.lock_tree_incidents(interval);

CREATE FUNCTION @extschema@.lock_tree_incidents(
  max_gap interval DEFAULT interval '5 minutes',
  since    interval DEFAULT NULL
)
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
    -- coalesce, not "since IS NULL OR sampled_at >= ...". The OR form cannot become an Index Cond,
    -- so it would make even a call with no arguments scan the whole index. This keeps the form the
    -- planner can seek with, and a NULL since becomes -infinity, which every row passes.
    WHERE sampled_at >= coalesce(statement_timestamp() - since, '-infinity'::timestamptz)
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

COMMENT ON FUNCTION @extschema@.lock_tree_incidents(interval, interval) IS
  'The sampled history grouped into incidents: runs of samples with no gap longer than '
  'max_gap (default 5 minutes). For each, when it ran, how many sessions were blocked at '
  'the worst, the deepest chain, the longest wait, and which root pids and application names '
  'were involved. Empty history returns no rows rather than an error. since (added 1.1.0) bounds '
  'the window and defaults to NULL, meaning all retained history, which is what this did before.';

-- No one-argument overload is left behind, and none is needed. max_gap is still the first parameter
-- and since has a default, so every existing positional call, lock_tree_incidents(interval '40
-- minutes') and the rest, resolves to the same function with the same meaning. A second overload
-- would be a second name for the same behaviour and one more thing to keep in step.