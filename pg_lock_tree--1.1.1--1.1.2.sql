/* pg_lock_tree--1.1.1--1.1.2.sql
 *
 * One change: lock_tree_incidents() takes the DISTINCT before building each array, not inside
 * array_agg. It returns the same rows and the same arrays as 1.1.1 for every argument, NULLs
 * included, and is faster because the work changed shape rather than amount:
 *
 *   array_agg(DISTINCT x ORDER BY x)   sorts every row in the incident's range, to emit a handful of
 *                                      values. On the standard seven-day fixture (1,209,620 rows) that
 *                                      sort spilled to disk, 14 MB at a time, once per array column.
 *   SELECT DISTINCT x, then array_agg  a hash aggregate over the rows, which does not spill, and a
 *                                      sort over only the distinct values.
 *
 * CREATE OR REPLACE rather than DROP and CREATE, because the signature is unchanged. Nothing that
 * depends on the function is disturbed and its grants are kept.
 *
 * The body and the COMMENT below are copied from pg_lock_tree--1.1.2.sql, not written again. The
 * COMMENT is unchanged from 1.1.1 and is restated anyway, so that the two files carry the same text
 * and a later edit to one of them cannot leave an upgraded database holding the other.
 */

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_incidents(
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
         --
         -- The DISTINCT is taken in a subquery before the array is built, not inside array_agg
         -- (1.1.2). array_agg(DISTINCT x ORDER BY x) sorts every row in the incident's range to
         -- emit a handful of values, and on a seven-day history that sort spilled to disk once per
         -- column. A bare DISTINCT is a hash aggregate, and only the distinct values are sorted.
         -- The result is the same, NULLs included: DISTINCT keeps one NULL and array_agg keeps it,
         -- sorted last, exactly as array_agg(DISTINCT ...) did. applications has always carried a
         -- NULL element when a session had no application_name, and still does.
         (SELECT array_agg(d.root_pid ORDER BY d.root_pid)
            FROM (SELECT DISTINCT h.root_pid
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)) d),
         (SELECT array_agg(d.application_name ORDER BY d.application_name)
            FROM (SELECT DISTINCT h.application_name
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)) d),
         -- Nulls excluded rather than rendered as empty strings: an empty element in this array
         -- would be indistinguishable from a prepared root whose object could not be resolved,
         -- and neither is worth a slot.
         (SELECT array_agg(d.root_object ORDER BY d.root_object)
            FROM (SELECT DISTINCT h.root_object
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)
                     AND h.root_object IS NOT NULL) d)
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
