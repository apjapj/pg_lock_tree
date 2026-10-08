-- pg_lock_tree 1.1.8 -> 1.1.10, DIRECT
--
-- Why this file exists, when every other release ships one step. pg_lock_tree--1.1.8--1.1.9.sql drops
-- and recreates lock_tree_archive_find(), because 1.1.9 removed its `samples` output column and an OUT
-- column cannot be removed by CREATE OR REPLACE. Before the DROP it checks for dependents, and that
-- check was wrong (the comment above the DO block below has the three ways). 1.1.9 is a released and
-- frozen tag, so its script is not edited. A 1.1.9--1.1.10 step cannot fix it either, because by then
-- the check has already run. So this path goes from 1.1.8 to 1.1.10 in one step, and PostgreSQL takes
-- it because ALTER EXTENSION ... UPDATE follows the SHORTEST path: one script beats two.
-- scripts/check-upgrade.sh asserts that from pg_extension_update_paths() rather than assuming it.
--
-- What it does, in order: the corrected dependents check; the DROP of both functions; and both
-- recreated as 1.1.10 defines them, which is 1.1.9's definitions plus the two text corrections in
-- pg_lock_tree--1.1.9--1.1.10.sql. Everything else 1.1.8 -> 1.1.9 did is in those two functions, so
-- nothing is lost by skipping the step.
--
-- An explicit ALTER EXTENSION pg_lock_tree UPDATE TO '1.1.9' still runs the old check. It is still
-- safe, since the DROP refuses on its own and the update rolls back, but its message is PostgreSQL's
-- generic one. INSTALL.md says to go straight to 1.1.10.

-- Refuse, with a message that names every dependent, before the DROP below would refuse anyway.
--
-- This is the 1.1.10 rewrite of the check 1.1.9 shipped in pg_lock_tree--1.1.8--1.1.9.sql, and that
-- one is left as it was because 1.1.9 is a frozen tag. Three things were wrong with it, all found by
-- review and all reproduced before being fixed:
--
--   1. It found the dependent view and then joined pg_proc on proname = 'lock_tree_archive_find'
--      INSIDE THE VIEW'S SCHEMA. A view in any schema other than the extension's matched no function
--      there, so the check passed silently.
--   2. When the view was in the extension's schema, the name it printed was that of the function the
--      join found, public.lock_tree_archive_find, and not the view's own.
--   3. Its comment said an upgrade that aborts halfway leaves the extension with a function missing.
--      It does not. ALTER EXTENSION ... UPDATE runs in one transaction, and DROP FUNCTION without
--      CASCADE refuses on its own while anything depends on the function, so the update rolls back
--      whole: the version stays 1.1.8 and the function keeps its seven columns. That is the real
--      safety story, and it held in 1.1.9 too. What 1.1.9 lost was the message, not the safety.
--
-- So this check does not make the upgrade safe; DROP already does. What it adds is an error that says
-- which objects to drop and recreate, by their own schema-qualified names, with the steps.
--
-- REFUSE, not warn. Warn-and-continue is not actually available: the DROP that follows would fail on
-- the same dependency, and the only way past it is CASCADE, which would delete the operator's views
-- without asking. A clear refusal or PostgreSQL's generic one are the only two outcomes, and this is
-- the clear one. 2BP01 is dependent_objects_still_exist, the code the DROP itself would raise, so a
-- caller matching on the code sees the same thing either way.
--
-- What it can find: views and materialized views (through pg_rewrite), and SQL-standard function
-- bodies, BEGIN ATOMIC or RETURN, which record their dependencies in pg_depend since PostgreSQL 14.
-- What it cannot find: a plpgsql function, or a LANGUAGE sql function with a string body, that calls
-- lock_tree_archive_find(). Neither records a dependency, so nothing in the catalog links them, and
-- the message says so in a sentence the operator has to act on.
DO $guard$
DECLARE
  dependents text;
BEGIN
  SELECT string_agg(DISTINCT dep.name, ', ' ORDER BY dep.name)
    INTO dependents
    FROM (
      -- Views and materialized views. ev_class is the view; format('%I.%I') rather than ::regclass,
      -- because regclass drops the schema of anything on the search_path, and during an extension
      -- script that is exactly the extension's schema: the case that printed the wrong name in 1.1.9.
      SELECT format('%s %I.%I',
                    CASE c.relkind WHEN 'm' THEN 'materialized view' ELSE 'view' END,
                    n.nspname, c.relname) AS name
        FROM pg_depend d
        JOIN pg_rewrite r   ON r.oid = d.objid
        JOIN pg_class c     ON c.oid = r.ev_class
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE d.classid = 'pg_rewrite'::regclass
         AND d.refclassid = 'pg_proc'::regclass
         AND d.refobjid IN (
               '@extschema@.lock_tree_archive_find(interval,interval,text,text,interval,integer)'::regprocedure,
               '@extschema@.lock_tree_archive_since_guard(interval)'::regprocedure)
         -- Not one of this extension's own objects. None depends on these two today; the filter is
         -- here so a future release that adds one does not refuse its own upgrade.
         AND NOT EXISTS (SELECT 1 FROM pg_depend e
                          WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid
                            AND e.refclassid = 'pg_extension'::regclass AND e.deptype = 'e')
      UNION ALL
      -- SQL-standard function bodies. The only kind of wrapper function the catalog can see.
      SELECT format('function %I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
        FROM pg_depend d
        JOIN pg_proc p      ON p.oid = d.objid
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE d.classid = 'pg_proc'::regclass
         AND d.refclassid = 'pg_proc'::regclass
         AND d.refobjid IN (
               '@extschema@.lock_tree_archive_find(interval,interval,text,text,interval,integer)'::regprocedure,
               '@extschema@.lock_tree_archive_since_guard(interval)'::regprocedure)
         AND NOT EXISTS (SELECT 1 FROM pg_depend e
                          WHERE e.classid = 'pg_proc'::regclass AND e.objid = p.oid
                            AND e.refclassid = 'pg_extension'::regclass AND e.deptype = 'e')
    ) dep;

  IF dependents IS NOT NULL THEN
    RAISE EXCEPTION
      'pg_lock_tree cannot update from 1.1.8: lock_tree_archive_find() loses its "samples" output column, so it has to be dropped and recreated, and these depend on it: %', dependents
      USING ERRCODE = '2BP01',
            DETAIL = 'Nothing has been changed: the update has been rolled back and the extension is still at 1.1.8. The new result has six columns, not seven: sampled_at, peak_sessions, longest_wait, total_wait, applications, queries. "samples" is gone; it was the constant 1.',
            HINT = 'Save each definition (pg_get_viewdef or pg_get_functiondef), DROP them, run ALTER EXTENSION pg_lock_tree UPDATE again, then recreate them without "samples". Functions that call lock_tree_archive_find() from a plpgsql or string SQL body record no dependency and cannot be listed here: check those by hand, because they will fail on their next call.';
  END IF;
END
$guard$;

-- Dropped, not replaced, because an OUT column cannot be removed by CREATE OR REPLACE. The order of
-- the two DROPs does not matter: a plpgsql body records no dependency on the functions it calls, and
-- both are recreated below in the same transaction. (1.1.9's comment here gave a reason for the order;
-- it was not one.) The REVOKEs are re-issued at the end because a recreated function starts with the
-- default privileges, not those of the one it replaces.
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
-- Two things follow from that table, and 1.1.9 drew the second one wrongly.
--
-- The bounded cases are NOT flat, and 1.1.8's 1.6/1.5/1.4 ms were not a flat plane that the BRIN
-- produced; they were three empty windows. Cost rises with rows read, as it does everywhere. And the
-- unbounded case does NOT hang: 1.1.8's "did not finish in 10 minutes" was an autovacuum of a
-- freshly-archived 1.3 GB table competing for a 128 MB buffer pool.
--
-- 1.1.9 then read the 60-day row (820 ms) against the unbounded one (319 ms) and concluded that the
-- index is a PENALTY at full coverage, about 2.5 times. That is also wrong. The 319 ms was a parallel
-- sequential scan with two workers and the 820 ms a single-backend bitmap scan, so the two rows differ
-- in parallelism, not in whether the index helps. 1.1.10 measured it directly, holding everything but
-- the plan fixed: 1,209,600 archived rows aged 7 to 14 days, physically in sampled_at order
-- (pg_stats correlation 1.0), PostgreSQL 18, shared_buffers 128MB, best of three, count(*) and
-- count(DISTINCT sampled_at) over the window:
--
--   window    rows read   planner (bitmap)   forced seq scan   forced seq, no parallel
--   8 days      172,760            71 ms            164 ms             296 ms
--   10 days     518,340           249 ms            389 ms             399 ms
--   11 days     691,140           346 ms            450 ms             456 ms
--   13 days   1,036,700           495 ms            526 ms             531 ms
--   none      1,209,600     no bound: seq scan, 353 to 381 ms
--
-- The bitmap scan wins at every coverage measured, from 14% to 86% of the rows. The index is not a
-- penalty; a window that covers nearly everything simply reads nearly everything, and a query with no
-- predicate at all is a little cheaper than one that evaluates a predicate on every row. An
-- independent run on a fixture of the same size reported correlation 0.9998619 and the same ordering
-- at every coverage, including 100%.
--
-- And the scan is not most of the cost. lock_tree_archive_find() itself, on the same windows, took
-- 467 ms, 1.42 s, 1.88 s, 2.25 s and 2.63 s: four to seven times the scan, because the per-sample
-- aggregation (two DISTINCT array_aggs) is the expensive part. So what a narrower window buys is fewer
-- rows aggregated, in proportion; it is worth having, and it is not the difference between an answer
-- and a hang.
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
  'Search lock_tree_history_archive, and ONLY the archive: a since window is required, and until defaults to now. One row per sample instant that matched, newest first, capped at limit_rows which defaults to 200, so a search over a year of history returns something readable. Filters: waiting_like is a CASE-INSENSITIVE SUBSTRING of the lock tag, with % and _ matched literally rather than as wildcards; application is an exact application_name; min_wait drops samples whose wait was below it. All filters are optional and a NULL filter matches everything. since is required because a NULL cannot become an index bound and would become a full scan; it is NOT a performance bound, so a window far wider than the archive is accepted and will read all of it. Measured on 5,184,000 archived rows spread over 7 to 67 days at 664 MB on PostgreSQL 18: a 7-day window reading 0 rows took 1.5 ms, 20 days reading 1,122,915 rows took 241 ms, and no window over all 5,184,000 rows took 319 ms on a parallel sequential scan. Cost follows the rows the window contains. With the planner free to choose, a bitmap scan on the BRIN beat a forced sequential scan at every coverage measured, 14% to 86% of 1,209,600 physically ordered rows; the index is not a penalty at full coverage, which 1.1.9 said it was. Most of the cost is the per-sample aggregation rather than the scan: on that archive this function took 467 ms for 14% of the rows and 2.63 s for all of them. This is the only shipped function that reads the archive. It does not read the hot table, so a window that reaches into the last few days returns only what was already archived: use lock_tree_incidents() or lock_tree_replay() for the hot end and combine the two yourself. waiting_for is NULL on root rows, so a search for a lock tag finds the waiters and not the blockers holding them.';

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
      'lock_tree_archive_find() needs a since window, because a NULL cannot become an index bound and would scan the whole archive. Note that since is not a performance limit: a window wider than the archive is accepted and reads all of it. Cost follows the rows the window contains, so a narrower window is cheaper in proportion, but the window is never the difference between working and hanging.'
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
