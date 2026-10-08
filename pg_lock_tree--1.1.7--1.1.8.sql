-- pg_lock_tree 1.1.7 -> 1.1.8
--
-- The read side of the cold tier. 1.1.6 shipped lock_tree_history_archive write-only, and 1.1.7
-- made its size visible through lock_tree_history_size(). This adds the first shipped function that
-- READS it.
--
-- Two functions, and the second exists only because the first cannot do what it needs to do from a
-- SQL body. Nothing existing is replaced and nothing is dropped, so no result any shipped function
-- returns can change.
--
-- WHY A BOUND IS REQUIRED, measured on 10,160,640 archived rows spanning 16 days:
--
--   1-day window     1.6 ms     Bitmap Heap Scan on the BRIN index
--   7-day window     1.5 ms     Bitmap Heap Scan on the BRIN index
--   14-day window    1.4 ms     Bitmap Heap Scan on the BRIN index
--   no window        did not finish in 10 minutes
--
-- The bounded cases are flat because the BRIN prunes the other ranges away, which is the whole
-- reason the archive is BRIN-indexed. The unbounded case is a sequential scan plus a hash aggregate
-- over ten million rows: the same work an unbounded lock_tree_incidents() does on the hot table,
-- which is why that function's default is NULL and this one's is not. Requiring a bound turns a query
-- that hangs into one that is refused, with an error that says what the bound buys.
--
-- WHY THE GUARD IS A SEPARATE FUNCTION AND WHY THE READ IS PLPGSQL. Three attempts at enforcing the
-- bound from a LANGUAGE sql body all failed, and each failed while looking correct:
--
--   1. A guard function joined into the query and marked STABLE. The planner inlines a STABLE
--      function whose result feeds nothing but a filter and drops it. EXPLAIN showed a plan with no
--      call to it at all.
--   2. The same guard marked VOLATILE, so the planner may not elide it. The call appeared in the
--      plan and STILL did not fire, because it sat below the calling function's own LIMIT, and a
--      query that returns no rows never reaches the node beneath it.
--   3. The guard as a scalar subquery in the outer list. Under a LIMIT, still elided.
--
-- The working shape is a plpgsql wrapper whose FIRST statement is the check, before the query is
-- assembled, so no plan shape can avoid it. LANGUAGE plpgsql is forced by this rather than chosen,
-- and the release file says so where a reader would otherwise wonder why one function in a project
-- of SQL functions is not SQL.
--
-- The guard is VOLATILE, which is the guarantee that the planner must honour: not constant-folded,
-- not hoisted above the scan, not reordered past the point where it matters. The cost is that it is
-- never skipped, which is the entire intent. It is an argument check, not a computation.

-- Lifted verbatim from pg_lock_tree--1.1.8.sql so the two files cannot drift, and
-- scripts/check-upgrade.sh fails if they do.
CREATE FUNCTION @extschema@.lock_tree_archive_find(
  since        interval,
  until        interval DEFAULT NULL,
  waiting_like text     DEFAULT NULL,
  application  text     DEFAULT NULL,
  min_wait     interval DEFAULT NULL,
  limit_rows   integer  DEFAULT 200
)
RETURNS TABLE (
  sampled_at    timestamptz,
  samples       bigint,
  peak_sessions int,
  longest_wait  interval,
  total_wait    interval,
  applications  text[],
  queries       text[]
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  -- The check, first, before the query is assembled. It raises rather than returning a flag, so a
  -- caller that passes NULL gets an error naming the measurement rather than an empty answer.
  PERFORM @extschema@.lock_tree_archive_since_guard(since);

  -- One row per sample instant inside the window, and only samples that matched. Counting rows per
  -- timestamp is what a reader wants from an archive: how wide the queue got and for how long, not
  -- one row per blocked session per sample, which is the grain the history is stored at and which
  -- nobody wants to read directly.
  --
  -- The window is applied to sampled_at in both directions. until is optional and defaults to the
  -- present, which is a sensible thing for it to mean and is bounded; since is not optional because
  -- unbounded is the failure the guard exists to stop.
  --
  -- The LIKE on waiting_for is the one thing this does that no shipped function does, because "what
  -- contended" is not something the live tree can answer and is the main reason to keep an archive.
  -- A sequential scan is the right plan for it: BRIN cannot help a pattern match, and on the archive
  -- there is no hot path to protect. The exact-match filters on application_name and the window on
  -- sampled_at are all things the BRIN or an index can serve, so the planner chooses.
  RETURN QUERY
  WITH matched AS (
    SELECT a.sampled_at, a.pid, a.wait_age, a.application_name, a.query
    FROM @extschema@.lock_tree_history_archive a
    WHERE a.sampled_at >= statement_timestamp() - since
      AND a.sampled_at < coalesce(statement_timestamp() - until, statement_timestamp())
      -- NULL passes, so a caller who does not care about the lock tag does not have to name one.
      -- ILIKE rather than LIKE because a lock tag is a relation name and nobody types its case.
      AND (waiting_like IS NULL OR a.waiting_for ILIKE '%' || waiting_like || '%')
      AND (application IS NULL OR a.application_name = application)
      -- A null wait_age on a root row is not a short wait, it is an unrecorded one, so the
      -- comparison is explicit rather than relying on NULL ordering.
      AND (min_wait IS NULL
           OR (a.wait_age IS NOT NULL AND a.wait_age >= min_wait))
  ),
  per_sample AS (
    SELECT m.sampled_at,
           count(*)::int                          AS peak_sessions,
           max(m.wait_age)                        AS longest_wait,
           sum(coalesce(m.wait_age, interval '0')) AS total_wait,
           -- NULL elements excluded rather than rendered as empty: an empty application name in
           -- this array would be indistinguishable from a session that set one to the empty string,
           -- and lock_tree_duration_by_application() reports the empty case as its own row for the
           -- same reason.
           array_agg(DISTINCT m.application_name) FILTER (WHERE m.application_name IS NOT NULL)
                                                    AS applications,
           -- The distinct statements rather than one per session, because a sample of twelve waiters
           -- on the same SELECT is one statement that happened twelve times.
           array_agg(DISTINCT m.query) FILTER (WHERE m.query IS NOT NULL AND m.query <> '')
                                                    AS queries
    FROM matched m
    GROUP BY m.sampled_at
  )
  SELECT p.sampled_at,
         1::bigint   AS samples,
         p.peak_sessions,
         p.longest_wait,
         p.total_wait,
         p.applications,
         p.queries
  FROM per_sample p
  -- Newest first, and capped. A caller searching an archive is looking for when something happened,
  -- not for a census, and an uncapped result from a year of history is a result nobody reads.
  -- The cap is applied OUTSIDE the aggregation, so the per-sample figures are not silently wrong:
  -- only the number of instants returned is limited.
  ORDER BY p.sampled_at DESC
  LIMIT greatest(coalesce(limit_rows, 200), 1);
END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) IS
  'Search lock_tree_history_archive, and ONLY the archive: a since window is required, and until defaults to now. One row per sample instant that matched, newest first, capped at limit_rows which defaults to 200, so a search over a year of history returns something readable. Filters: waiting_like matches anywhere in the lock tag and is case-insensitive, application is an exact application_name, min_wait drops samples whose wait was below it. All filters are optional and a NULL filter matches everything. The bound is required and that is measured rather than stylistic: on 10,160,640 archived rows spanning 16 days a 7-day window returns in 1.5 ms using the BRIN index, and an unbounded query over the same rows did not finish in 10 minutes. This is the only shipped function that reads the archive. It does not read the hot table, so a window that reaches into the last few days returns only what was already archived: use lock_tree_incidents() or lock_tree_replay() for the hot end and combine the two yourself. waiting_for is NULL on root rows, so a search for a lock tag finds the waiters and not the blockers holding them.';

CREATE FUNCTION @extschema@.lock_tree_archive_since_guard(since interval)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
AS $$
BEGIN
  IF since IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_archive_find() needs a since window. Measured on 10,160,640 archived rows spanning 16 days: a 7-day window returns in 1.5 ms using the BRIN index, and an unbounded query over the same rows did not finish in 10 minutes. Pass a since, or write the query yourself against lock_tree_history_archive, which is a plain table and will scan it.'
      USING ERRCODE = '22023';
  END IF;
  RETURN true;
END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) IS
  'Refuses a NULL window for lock_tree_archive_find(), which needs a bound and cannot enforce one from a SQL body: a guard joined into the query is below its LIMIT and is never reached. Not useful on its own, call lock_tree_archive_find() instead.';

-- REVOKE, matching lock_tree_sample() and for the same reason. The guard raises, so a role that can
-- reach it can be told what the table is for by calling it, which is harmless; but the convention
-- here is that a function this project considers part of its own machinery is not PUBLIC, and an
-- operator granting EXECUTE on one of these is granting it without having read the argument list.
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) FROM PUBLIC;
