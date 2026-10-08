-- pg_lock_tree 1.1.9 -> 1.1.10
--
-- A soak release. This step changes two pieces of text in the catalog and nothing that runs:
--
--   1. lock_tree_archive_since_guard()'s error drops "a bound usually saves a factor of two to four".
--      Measured on 1,209,600 archived rows, lock_tree_archive_find() took 467 ms on a window holding
--      14% of them and 2.25 s on one holding 86%, against 2.63 s for all of them: the saving follows
--      the rows excluded, and no single factor describes it. The message now says that.
--   2. lock_tree_archive_find()'s COMMENT drops "at full coverage the index costs about 2.5 times an
--      unbounded scan". That compared a single-backend bitmap scan with a two-worker parallel
--      sequential scan. With the plan forced and everything else held fixed, the bitmap scan won at
--      every coverage measured, 14% to 86%. The figures are in pg_lock_tree--1.1.10.sql, above the
--      function.
--
-- The guard keeps its signature, so CREATE OR REPLACE keeps its privileges: it was revoked from
-- PUBLIC in 1.1.8 and stays revoked. Nothing else in the extension changes from 1.1.9.
--
-- The OTHER half of 1.1.10 is not in this file and could not be: the corrected dependents check runs
-- before lock_tree_archive_find() is dropped, which only happens on the way from 1.1.8. A database
-- already at 1.1.9 has been through that step. See pg_lock_tree--1.1.8--1.1.10.sql.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_archive_since_guard(since interval)
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

COMMENT ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) IS
  'Search lock_tree_history_archive, and ONLY the archive: a since window is required, and until defaults to now. One row per sample instant that matched, newest first, capped at limit_rows which defaults to 200, so a search over a year of history returns something readable. Filters: waiting_like is a CASE-INSENSITIVE SUBSTRING of the lock tag, with % and _ matched literally rather than as wildcards; application is an exact application_name; min_wait drops samples whose wait was below it. All filters are optional and a NULL filter matches everything. since is required because a NULL cannot become an index bound and would become a full scan; it is NOT a performance bound, so a window far wider than the archive is accepted and will read all of it. Measured on 5,184,000 archived rows spread over 7 to 67 days at 664 MB on PostgreSQL 18: a 7-day window reading 0 rows took 1.5 ms, 20 days reading 1,122,915 rows took 241 ms, and no window over all 5,184,000 rows took 319 ms on a parallel sequential scan. Cost follows the rows the window contains. With the planner free to choose, a bitmap scan on the BRIN beat a forced sequential scan at every coverage measured, 14% to 86% of 1,209,600 physically ordered rows; the index is not a penalty at full coverage, which 1.1.9 said it was. Most of the cost is the per-sample aggregation rather than the scan: on that archive this function took 467 ms for 14% of the rows and 2.63 s for all of them. This is the only shipped function that reads the archive. It does not read the hot table, so a window that reaches into the last few days returns only what was already archived: use lock_tree_incidents() or lock_tree_replay() for the hot end and combine the two yourself. waiting_for is NULL on root rows, so a search for a lock tag finds the waiters and not the blockers holding them.';
