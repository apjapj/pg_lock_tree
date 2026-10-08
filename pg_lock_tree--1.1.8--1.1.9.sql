-- pg_lock_tree 1.1.8 -> 1.1.9
--
-- Four defect fixes, three of them found by review and one by a planted test. Every one of them made
-- the extension claim something it was not, and two of the claims were in an error message a caller
-- would rely on.
--
-- 1. lock_tree_archive_find() drops its `samples` column.
--    It was hard-coded to 1::bigint, because the result is already one row per sample instant, so it
--    had exactly one distinct value across 100,000 rows. This is the only breaking change in the
--    release, and it is why the DROP below is checked for dependents rather than just issued.
--
-- 2. `waiting_like` escapes % and _, so it is a substring and not a pattern.
--    On 1.1.8 the argument went straight into ILIKE, so a search for a relation named t_ matched
--    every tag in the archive. Measured on a 5,184,000-row fixture: 't_' returned 2,708,221 samples
--    across four different tags, and 't%' returned every sample in the window, where no relation was
--    named t_ at all. Both now return nothing, and a real tag still matches.
--
-- 3. The `since` guard no longer claims to bound anything it cannot measure.
--    It refuses NULL and says what a wide window actually costs. It does NOT cap since: the archive's
--    span changes as rows are archived, so computing it would cost the scan the check exists to avoid.
--
-- 4. Every timing in 1.1.8's comments, in the guard's error message and in docs/reference.md was
--    measured on windows containing NO ROWS. 1.1.8 recorded "a 7-day window returns in 1.5 ms" from an
--    archive whose every row was already older than 28 days, so that window matched nothing, and
--    "an unbounded query did not finish in 10 minutes" from a run that was competing with an autovacuum
--    of a freshly-archived 1.3 GB table for a 128 MB buffer pool.
--
-- THE CORRECTED FIGURES, on a fixture with an explicit age distribution, 5,184,000 rows spread from 7
-- to 67 days at 664 MB, PostgreSQL 18. The rows-read column is the count(*) over the same window, so
-- a figure cannot be read as the cost of reading nothing:
--
--   window   rows read       time    plan
--   7 days           0     1.5 ms   Bitmap Heap Scan, every range pruned
--   14 days    604,523   133.7 ms   Bitmap Heap Scan
--   20 days  1,122,915   240.6 ms   Bitmap Heap Scan
--   30 days  1,986,923   386.1 ms   Bitmap Heap Scan
--   40 days  2,850,915   473.9 ms   Bitmap Heap Scan
--   60 days  4,578,922   820.3 ms   Bitmap Heap Scan
--   no window 5,184,000   319.1 ms   Parallel Seq Scan
--
-- The bounded cases are not flat, and 1.1.8's flat 1.6/1.5/1.4 ms were three empty windows. The
-- unbounded case does not hang. What is true is narrower: when the window prunes, the BRIN wins and
-- cost is roughly linear in rows read; when it does not, the index is a small PENALTY, since a
-- 60-day bitmap scan at 820 ms is slower than an unbounded parallel sequential scan at 319 ms. A
-- bound is worth having because it usually makes a search 2 to 4 times faster, not because the
-- alternative is unbounded time.
--
-- WHY A DROP AND NOT A REPLACE. `samples` is an OUT column, and CREATE OR REPLACE refuses a changed
-- return type outright ("cannot change return type of existing function"), so removing one cannot be
-- done by replacing. The DROP is preceded by a check that refuses to proceed if anything outside this
-- extension depends on the function, because an extension upgrade that aborts halfway leaves an
-- installed extension with a function missing, and the documented recovery for that is to drop and
-- recreate rather than to debug.
--
-- The REVOKEs are re-issued after the DROP, because a recreated function does not inherit the
-- privileges of the one it replaces.

-- Refuse to proceed if anything outside this extension depends on the two functions below. A view or
-- a function wrapping lock_tree_archive_find() would break silently at upgrade and loudly later, and
-- silently-then-loudly is the worst order. pg_depend lists only extension members, so a dependency
-- from outside is exactly the row that would be missing.
DO $guard$
DECLARE
  dependents text;
BEGIN
  SELECT string_agg(DISTINCT dependent_ns.nspname || '.' || dependent_pr.proname,
                     ', ' ORDER BY dependent_ns.nspname || '.' || dependent_pr.proname)
    INTO dependents
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
    JOIN pg_class dependent_view ON dependent_view.oid = r.ev_class
    JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
    JOIN pg_proc dependent_pr ON dependent_pr.pronamespace = dependent_ns.oid
                         AND dependent_pr.proname = 'lock_tree_archive_find'
    WHERE d.refobjid IN (
            'lock_tree_archive_find(interval,interval,text,text,interval,integer)'::regprocedure,
            'lock_tree_archive_since_guard(interval)'::regprocedure)
      AND NOT EXISTS (SELECT 1 FROM pg_depend ext_d
                       WHERE ext_d.objid = d.objid
                         AND ext_d.refclassid = 'pg_extension'::regclass);

  IF dependents IS NOT NULL THEN
    RAISE EXCEPTION
      'pg_lock_tree 1.1.9 removes lock_tree_archive_find()''s "samples" output column, so the '
      'function has to be dropped and recreated, and these depend on it: %. Recreate them after the '
      'upgrade: the new result is one row per sample instant with six columns, not seven.',
      dependents;
  END IF;
END
$guard$;

-- Dropped, not replaced. See above for why the dependents are checked first and why the REVOKEs
-- follow. The guard goes first because archive_find() calls it, and dropping the caller before the
-- callee would leave a body that names a function that no longer exists.
DROP FUNCTION @extschema@.lock_tree_archive_since_guard(interval);
DROP FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer);

-- Search the archive. Added in 1.1.8, and corrected here in 1.1.9: three of its comments and its
-- error message carried measurements taken on windows that contained no rows.
--
-- It searches ONLY the archive. It does not span hot and cold, and that is a decision with a
-- measurement behind it rather than a shortcut. Teaching the existing read functions to span both
-- was tried in 1.1.6 and measured: with the archive as a UNION ALL on the inner side of the
-- root-to-waiter join, the planner stops choosing the index probe and a Nested Loop Semi Join at
-- 96 ms becomes a HashAggregate over a sequential scan of both tables at 924 ms, and an EMPTY
-- archive still costs 50%, so installations that never archive would pay for a feature they do not
-- use. Nothing here is a join, so that specific penalty does not apply, but the reasoning transfers:
-- a function that reads two tables is two queries to reason about, and the boundary is where a caller
-- is most likely to get a silently short answer.
--
-- THE BOUND, AND WHAT IT ACTUALLY BUYS. The window is required, because a NULL cannot be turned into
-- an index bound. It is NOT a performance bound, and 1.1.8 said it was, which was wrong.
--
-- 1.1.8's figures were measured on an archive whose every row was already older than 28 days, and a
-- "7-day window" over that archive matches nothing: 1.5 ms and zero rows. The BRIN pruned every range
-- and the query returned an empty result, and that was recorded as the cost of reading the archive.
--
-- Re-measured on a fixture with an EXPLICIT age distribution, 5,184,000 rows spread from 7 to 67 days
-- at 664 MB, PostgreSQL 18, shared_buffers 128MB. The rows read column is the count(*) over the same
-- window, so a figure cannot be mistaken for the cost of reading nothing:
--
--   window   rows read       time    plan
--   7 days           0     1.5 ms   Bitmap Heap Scan, every range pruned
--   14 days    604,523   133.7 ms   Bitmap Heap Scan
--   20 days  1,122,915   240.6 ms   Bitmap Heap Scan
--   30 days  1,986,923   386.1 ms   Bitmap Heap Scan
--   40 days  2,850,915   473.9 ms   Bitmap Heap Scan
--   60 days  4,578,922   820.3 ms   Bitmap Heap Scan
--   no window 5,184,000   319.1 ms   Parallel Seq Scan
--
-- Two things follow, and the second is the one 1.1.8 got backwards.
--
-- The bounded cases are NOT flat, and 1.1.8's 1.6/1.5/1.4 ms were not a flat plane that the BRIN
-- produced; they were three empty windows. Cost rises with rows read, as it does everywhere.
--
-- And the unbounded case does NOT hang. 1.1.8 recorded "did not finish in 10 minutes"; it finishes in
-- 319 ms. That figure measured an autovacuum of a freshly-archived 1.3 GB table competing for a
-- 128 MB buffer pool, and contention was recorded as the query's cost.
--
-- What is actually true is narrower and more useful: when the window prunes, the BRIN wins and the
-- cost is roughly linear in rows read; when it does not prune, the index is a small PENALTY, since a
-- 60-day bitmap scan at 820 ms is slower than an unbounded parallel sequential scan at 319 ms over
-- the same table. So a bound is worth having because it usually makes things 2 to 4 times faster, not
-- because the alternative is unbounded time.
--
-- The LIKE on waiting_for is the one thing this does that no shipped function does, because "what
-- contended" is not something the live tree can answer and is the main reason to keep an archive. A
-- sequential scan is the right plan for it: BRIN cannot help a pattern match, and on the archive
-- there is no hot path to protect. The exact-match filters on application_name and the window on
-- sampled_at are all things the BRIN or an index can serve, so the planner chooses.
--
-- plpgsql, not sql, and that is forced by the guard. See lock_tree_archive_since_guard() below for
-- what went wrong with the SQL version and why a plan shape cannot express this check.
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
  -- present, which is a sensible thing for it to mean; since is not optional because a NULL cannot
  -- become an index bound and would silently become a full scan.
  --
  -- No `samples` column in 1.1.9. It was here in 1.1.8 and was hard-coded to 1::bigint, because the
  -- result is already one row per instant and the column therefore carried no information at all: one
  -- distinct value across 100,000 rows. A column that cannot vary is a column a caller has to wonder
  -- about, and it was dropped rather than given a meaning it could not have.
  RETURN QUERY
  WITH matched AS (
    SELECT a.sampled_at, a.pid, a.wait_age, a.application_name, a.query
    FROM @extschema@.lock_tree_history_archive a
    WHERE a.sampled_at >= statement_timestamp() - since
      AND a.sampled_at < coalesce(statement_timestamp() - until, statement_timestamp())
      -- NULL passes, so a caller who does not care about the lock tag does not have to name one.
      --
      -- ESCAPED, which is the 1.1.9 correction. This was ILIKE '%' || waiting_like || '%', so the
      -- argument behaved as a PATTERN and a search for a relation named t_ matched every tag in the
      -- archive. Measured on the 5,184,000-row fixture: waiting_like => 't_' returned 2,708,221
      -- samples across four different tags, and 't%' returned every sample, where no relation was
      -- named t_ at all. With both characters escaped, 't_' correctly returns nothing.
      --
      -- The argument is documented and named as a SUBSTRING, which is what a DBA searching for a lock
      -- tag means. The escape character is a backslash, chosen because it is not the default for
      -- ILIKE and therefore does not collide with a caller's own habit, and the backslash itself is
      -- doubled first so a caller can still match a literal one.
      AND (waiting_like IS NULL
           OR a.waiting_for ILIKE '%'
                || replace(replace(replace(waiting_like, '\', '\\'), '%', '\%'), '_', '\_')
                || '%' ESCAPE '\')
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
  'Search lock_tree_history_archive, and ONLY the archive: a since window is required, and until defaults to now. One row per sample instant that matched, newest first, capped at limit_rows which defaults to 200, so a search over a year of history returns something readable. Filters: waiting_like is a CASE-INSENSITIVE SUBSTRING of the lock tag, with % and _ matched literally rather than as wildcards; application is an exact application_name; min_wait drops samples whose wait was below it. All filters are optional and a NULL filter matches everything. since is required because a NULL cannot become an index bound and would become a full scan; it is NOT a performance bound, so a window far wider than the archive is accepted and will read all of it. Measured on 5,184,000 archived rows spread over 7 to 67 days at 664 MB on PostgreSQL 18: a 7-day window reading 0 rows took 1.5 ms, 20 days reading 1,122,915 rows took 241 ms, and no window over all 5,184,000 rows took 319 ms on a parallel sequential scan. So a bound usually makes a search 2 to 4 times faster, and at full coverage the index costs about 2.5 times an unbounded scan rather than preventing one. This is the only shipped function that reads the archive. It does not read the hot table, so a window that reaches into the last few days returns only what was already archived: use lock_tree_incidents() or lock_tree_replay() for the hot end and combine the two yourself. waiting_for is NULL on root rows, so a search for a lock tag finds the waiters and not the blockers holding them.';

-- The argument check for lock_tree_archive_find(), which needs a bound it cannot express in a SQL
-- body. Its only purpose is to be called by that function; calling it directly does nothing useful.
--
-- VOLATILE, and the reason is a history worth keeping. Written STABLE first, on the reasoning that it
-- only inspects its argument, and the guard then SILENTLY DID NOT FIRE: a STABLE function whose result
-- feeds nothing but a filter is inlined and dropped by the planner, and EXPLAIN showed a plan with no
-- call to it at all. Rewritten VOLATILE the call appeared in the plan and still did not fire, because
-- it sat below the calling function's own LIMIT, and a query that returns no rows never reaches the
-- node beneath it.
--
-- The conclusion, and it is narrower than "VOLATILE is load-bearing": volatility was necessary for
-- the SQL-body shape and is IRRELEVANT for the shape that shipped. A STABLE guard called from a STABLE
-- plpgsql PERFORM fires perfectly, because there is no plan for a planner to fold anything into. The
-- reason the guard works is the PERFORM being the first statement, not the volatility. VOLATILE is kept
-- because it is the honest description of a function that raises, and because removing it would imply
-- the check can be folded away.
CREATE FUNCTION @extschema@.lock_tree_archive_since_guard(since interval)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
AS $$
BEGIN
  IF since IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_archive_find() needs a since window, because a NULL cannot become an index bound and would scan the whole archive. Note that since is not a performance limit: a window wider than the archive is accepted and reads all of it. Measured on 5,184,000 archived rows spread over 7 to 67 days on PostgreSQL 18, a window reading 1,122,915 rows took 241 ms and an unbounded query over all 5,184,000 took 319 ms, so a bound usually saves a factor of two to four but is not the difference between working and hanging.'
      USING ERRCODE = '22023';
  END IF;
  RETURN true;
END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) IS
  'Refuses a NULL window for lock_tree_archive_find(), which needs a bound and cannot enforce one from a SQL body: a guard joined into the query is below its LIMIT and is never reached. Refuses NULL only. A very wide since is accepted, because the archive''s span changes as rows are archived and computing it would cost the scan the check exists to avoid. Not useful on its own, call lock_tree_archive_find() instead.';

-- REVOKE, matching lock_tree_sample() and for the same reason. The guard raises, so a role that can
-- reach it can be told what the table is for by calling it, which is harmless; but the convention
-- here is that a function this project considers part of its own machinery is not PUBLIC, and an
-- operator granting EXECUTE on one of these is granting it without having read the argument list.
--
-- Deliberately NOT revoking lock_tree_archive(), the PROCEDURE, even though the sibling functions
-- are revoked. That one is called by an operator's scheduled job and has to be callable by whoever
-- runs it, and lock_tree_prune_batched() is PUBLIC for the same reason. The distinction is who calls
-- it: a function nobody is meant to call by accident is revoked, and a procedure an operator
-- schedules is not.
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) FROM PUBLIC;
