-- pg_lock_tree 1.1.4 -> 1.1.5
--
-- Two function bodies. Both are lifted verbatim from pg_lock_tree--1.1.5.sql, so the two files
-- cannot drift. Both use CREATE OR REPLACE, which is required to replace an existing function and
-- is the whole reason this script is not a copy of the release declarations: lifted verbatim with
-- plain CREATE, the upgrade fails with "function already exists with same argument types".
--
-- The change is one added predicate in each: the waiter side of the root-to-waiter join is bounded
-- by the same window as the root side.
--
-- It cannot change the result. The join equates w.sampled_at with r.sampled_at, and r.sampled_at is
-- already bounded, so the set of matching rows is identical. What changes is how many rows are read
-- to find them. Verified identical output at 8 windows from NULL to 100 days, 16 of 16 cases on a
-- 90-day fixture and 16 of 16 on a varied small fixture with several applications, several query
-- ids, NULL and empty application names and root objects, pid 0 roots and gaps, 48 result rows.
-- Each old and new pair was run inside one statement so both saw the same statement_timestamp();
-- running them in separate statements measures the clock, because the window boundary moves
-- between calls and these functions do not agree with themselves across two consecutive calls.
--
-- Why it was needed, and why it looked intermittent. PostgreSQL does not carry a >= bound on
-- r.sampled_at across the equality w.sampled_at = r.sampled_at. Whether the waiter side therefore
-- stayed inside the window depended on which join the planner chose: a nested loop probes it and
-- reads about 19 rows per root, a merge or hash join or a sequential scan reads every depth > 0 row
-- in the table. That is a property of the plan, not of the SQL, and it moved with version,
-- statistics and fixture size.
--
-- Measured on the default 7-day window, stock 1.1.4 against 1.1.5:
--
--   PG18, 90-day fixture   duration()  19 waiter rows, unchanged plan, 2,448 ms against 2,448 ms
--                          by_application()  14,774,419 rows against 1,148,664; 7,035 ms against 2,136 ms
--   PG14, 30-day fixture   duration()  19 waiter rows, unchanged plan, 2,351 ms against 2,329 ms
--                          by_application()  4,924,819 rows against 1,148,835; 3,449 ms against 2,377 ms
--
-- duration() is bounded too even though its plan does not change on a healthy fixture, because that
-- is not guaranteed: on PG14 with unusable statistics it degraded to a sequential scan over every
-- waiter row, 7,917 ms against 2,806 ms with the bound. Stating the bound removes the dependency on
-- planner behaviour that has already been observed to move.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_duration(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  query_id             bigint,
  blocking_seconds     numeric,
  samples              bigint,
  gaps                 bigint,
  gaps_excluded        bigint,
  blocked_sessions_peak bigint,
  sessions_total       bigint,
  longest_wait         interval,
  first_blocked_at     timestamptz,
  last_blocked_at      timestamptz,
  applications         text[]
)
LANGUAGE sql STABLE
AS $$
-- The window is applied to the INSTANTS first, before any gap is formed. Applying it afterwards
  -- would compute a gap from a sample outside the window and then discard the gap for having one
  -- endpoint out of range, which silently drops the boundary sample the reader asked about.
  WITH kept AS (
    SELECT DISTINCT h.sampled_at
    FROM @extschema@.lock_tree_history h
    WHERE h.sampled_at >= statement_timestamp() - since
  ),
  spans AS (
    SELECT sampled_at AS from_at,
           lead(sampled_at) OVER (ORDER BY sampled_at) AS to_at
    FROM kept
  ),
  -- The root query_ids present at each instant, as one row per (instant, query_id). Forming this once
  -- and joining on both ends is what keeps this linear in the number of samples: the first draft
  -- cross-joined spans against the query list and then tested both endpoints with EXISTS inside the
  -- projection, which is O(gaps x queries) probes over a table that grows all day.
  rooted AS (
    SELECT DISTINCT h.sampled_at, h.query_id
    FROM @extschema@.lock_tree_history h
    WHERE h.query_id IS NOT NULL
      AND h.depth = 0
      AND h.sampled_at >= statement_timestamp() - since
  ),
  gaps AS (
    SELECT r.query_id,
           s.from_at,
           s.to_at,
           s.to_at - s.from_at AS span,
           -- The join to the second copy of `rooted` is what enforces "root at both ends", and a gap
           -- whose far end has a different root is DISCARDED rather than apportioned: nobody observed
           -- when the handover happened, so any split of that gap would be invented.
           (t.query_id IS NOT NULL) AS held_both_ends
    FROM spans s
    JOIN rooted r      ON r.sampled_at = s.from_at
    LEFT JOIN rooted t ON t.sampled_at = s.to_at AND t.query_id = r.query_id
    WHERE s.to_at IS NOT NULL
  ),
  totals AS (
    SELECT query_id,
           -- sum() over interval works, but the result is an interval, and a duration in seconds is
           -- what a reader compares across queries and against a budget. Kept as numeric so a
           -- fractional second survives rather than being rounded away.
           sum(span) FILTER (WHERE held_both_ends)     AS held,
           count(*) FILTER (WHERE held_both_ends)     AS n_held,
           count(*) FILTER (WHERE NOT held_both_ends) AS n_dropped
    FROM gaps
    GROUP BY query_id
  ),
  -- Fixed in 0.13. A root's IDENTITY and the waits it CAUSED are on different rows: query_id is on
  -- the root row, wait_age is on the waiter's. 0.12 grouped by query_id and took max(wait_age) from
  -- the same rows, which is always NULL, because the rows carrying the query_id have no wait on them.
  -- So blocked_sessions_peak was always 1, since there is exactly one root row per query per sample,
  -- sessions_total was that same 1 summed, and longest_wait was NULL. Three columns, one mistake.
  --
  -- This is the join that answers all three: the root rows of a sample, matched to the waiter rows
  -- of the SAME sample by root_pid and root_object. The object is part of the match for the same
  -- reason it is half of lock_tree_alert's primary key: pid 0 is every prepared transaction at once,
  -- so matching on pid alone would attribute one prepared root's waiters to another.
  root_wait AS (
    SELECT r.query_id,
           r.sampled_at,
           max(w.wait_age) AS wait_at,
           count(w.pid)    AS waiters_at
    FROM @extschema@.lock_tree_history r
    JOIN @extschema@.lock_tree_history w
      ON w.sampled_at = r.sampled_at
     AND w.root_pid  = r.root_pid
     AND coalesce(w.root_object, '') = coalesce(r.root_object, '')
     -- AND w.depth > 0, and that clause is a bug fixed in 0.15 rather than a style choice. A root row
     -- carries its own pid in root_pid, so the join above matched every root to ITSELF and
     -- count(w.pid) counted the blocker among its own blocked. Measured: a root with two waiters
     -- behind it reported blocked_sessions_peak = 3.
     --
     -- It survived because test/17 computed its expected peak with the same self-matching join, so the
     -- test agreed with the bug and passed. An expectation derived from the expression under test is
     -- not an expectation. test/19's fixture is built from depth values directly and is what caught
     -- it.
     AND w.depth > 0
    -- 1.1.5: the waiter side is bounded explicitly. PostgreSQL does not carry a >= bound on
    -- r.sampled_at across the equality w.sampled_at = r.sampled_at, so before this the waiter
    -- side stayed inside the window only if the planner happened to pick a nested loop and probe
    -- it. That is a property of the chosen join, not of the SQL, and it varied with version and
    -- fixture: on PG18 with a 90-day fixture this function read 14,774,419 waiter rows for a
    -- 7-day question, and on PG14 with a 30-day one it read 4,924,819, both with only a Filter and
    -- no index bound. lock_tree_duration() has the same join and got a nested loop on both, so it
    -- read 19 rows per probe, which is why the two disagreed despite identical SQL.
    --
    -- It cannot change which rows match: w.sampled_at = r.sampled_at and r.sampled_at is already
    -- bounded, so an unbounded w can only change how much has to be read. Stating the bound makes
    -- the bounded plan the only one available, rather than leaving the cost to the planner.
    -- Applied to lock_tree_duration() as well, whose plan is fast today and need not stay that way: on PG14 with
    -- broken statistics it degraded to a sequential scan over every waiter row, 7,917 ms against
    -- 2,806 ms with the bound.
    AND w.sampled_at >= statement_timestamp() - since
    WHERE r.depth = 0
      AND r.query_id IS NOT NULL

      AND r.sampled_at >= statement_timestamp() - since
    GROUP BY r.query_id, r.sampled_at
  ),
  -- One row per query_id. Grouped here rather than in root_wait so that the peak can be a maximum
  -- OF the per-sample counts; a peak cannot be recovered from a total.
  per_query AS (
    SELECT query_id,
           max(waiters_at) AS sessions_peak,
           sum(waiters_at) AS sessions_total,
           max(wait_at)    AS longest_wait,
           count(*)        AS samples,
           min(sampled_at) AS first_at,
           max(sampled_at) AS last_at
    FROM root_wait
    GROUP BY query_id
  ),
  apps AS (
    -- NULL application_names excluded rather than collected: a depth-0 row for a session with no
    -- application_name would put a null in the array, which is indistinguishable from a gap in the
    -- data.
    SELECT query_id,
           array_agg(DISTINCT application_name ORDER BY application_name) AS names
    FROM @extschema@.lock_tree_history
    WHERE query_id IS NOT NULL
      AND application_name IS NOT NULL
      AND sampled_at >= statement_timestamp() - since
    GROUP BY query_id
  )
  SELECT t.query_id,
         round(extract(epoch FROM coalesce(t.held, interval '0'))::numeric, 3),
         p.samples,
         t.n_held,
         t.n_dropped,
         p.sessions_peak,
         p.sessions_total,
         p.longest_wait,
         p.first_at,
         p.last_at,
         a.names
  FROM totals t
  JOIN per_query p ON p.query_id = t.query_id
  LEFT JOIN apps a ON a.query_id = t.query_id
  -- Worst first, and by duration rather than by sample count, which is the entire difference.
  ORDER BY coalesce(t.held, interval '0') DESC, p.sessions_peak DESC
$$;

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_duration_by_application(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  application_name      text,
  blocking_seconds      numeric,
  samples               bigint,
  gaps                  bigint,
  gaps_excluded         bigint,
  blocked_sessions_peak bigint,
  sessions_total        bigint,
  longest_wait          interval,
  first_blocked_at      timestamptz,
  last_blocked_at       timestamptz,
  query_ids             bigint[]
)
LANGUAGE sql STABLE
AS $$
  WITH kept AS (
    SELECT DISTINCT h.sampled_at
    FROM @extschema@.lock_tree_history h
    WHERE h.sampled_at >= statement_timestamp() - since
  ),
  spans AS (
    SELECT sampled_at AS from_at,
           lead(sampled_at) OVER (ORDER BY sampled_at) AS to_at
    FROM kept
  ),
  -- DISTINCT on the application, not on the query. Two concurrent roots of one application at one
  -- instant are one row, so a gap in which it held both is counted once, which is what "this
  -- application held the queue up this long" has to mean. Counted per root it would double, and the
  -- figure would move with however many concurrent sessions the application happened to use.
  rooted AS (
    SELECT DISTINCT h.sampled_at, h.application_name
    FROM @extschema@.lock_tree_history h
    WHERE h.depth = 0
      AND h.application_name IS NOT NULL
      AND h.sampled_at >= statement_timestamp() - since
  ),
  gaps AS (
    SELECT r.application_name,
           s.from_at,
           s.to_at,
           s.to_at - s.from_at AS span,
           (t.application_name IS NOT NULL) AS held_both_ends
    FROM spans s
    JOIN rooted r      ON r.sampled_at = s.from_at
    LEFT JOIN rooted t ON t.sampled_at = s.to_at AND t.application_name = r.application_name
    WHERE s.to_at IS NOT NULL
  ),
  totals AS (
    SELECT application_name,
           sum(span) FILTER (WHERE held_both_ends)     AS held,
           count(*) FILTER (WHERE held_both_ends)     AS n_held,
           count(*) FILTER (WHERE NOT held_both_ends) AS n_dropped
    FROM gaps
    GROUP BY application_name
  ),
  -- The same root-to-waiter join lock_tree_duration() uses, grouped by application.
  root_wait AS (
    SELECT r.application_name,
           r.sampled_at,
           max(w.wait_age) AS wait_at,
           count(w.pid)    AS waiters_at
    FROM @extschema@.lock_tree_history r
    JOIN @extschema@.lock_tree_history w
      ON w.sampled_at = r.sampled_at
     AND w.root_pid  = r.root_pid
     AND coalesce(w.root_object, '') = coalesce(r.root_object, '')
     -- AND w.depth > 0, and that clause is a bug fixed in 0.15 rather than a style choice. A root row
     -- carries its own pid in root_pid, so the join above matched every root to ITSELF and
     -- count(w.pid) counted the blocker among its own blocked. Measured: a root with two waiters
     -- behind it reported blocked_sessions_peak = 3.
     --
     -- It survived because test/17 computed its expected peak with the same self-matching join, so the
     -- test agreed with the bug and passed. An expectation derived from the expression under test is
     -- not an expectation. test/19's fixture is built from depth values directly and is what caught
     -- it.
     AND w.depth > 0
    -- 1.1.5: the waiter side is bounded explicitly. PostgreSQL does not carry a >= bound on
    -- r.sampled_at across the equality w.sampled_at = r.sampled_at, so before this the waiter
    -- side stayed inside the window only if the planner happened to pick a nested loop and probe
    -- it. That is a property of the chosen join, not of the SQL, and it varied with version and
    -- fixture: on PG18 with a 90-day fixture this function read 14,774,419 waiter rows for a
    -- 7-day question, and on PG14 with a 30-day one it read 4,924,819, both with only a Filter and
    -- no index bound. lock_tree_duration() has the same join and got a nested loop on both, so it
    -- read 19 rows per probe, which is why the two disagreed despite identical SQL.
    --
    -- It cannot change which rows match: w.sampled_at = r.sampled_at and r.sampled_at is already
    -- bounded, so an unbounded w can only change how much has to be read. Stating the bound makes
    -- the bounded plan the only one available, rather than leaving the cost to the planner.
    -- Applied to lock_tree_duration_by_application() as well, whose plan is fast today and need not stay that way: on PG14 with
    -- broken statistics it degraded to a sequential scan over every waiter row, 7,917 ms against
    -- 2,806 ms with the bound.
    AND w.sampled_at >= statement_timestamp() - since
    WHERE r.depth = 0
      AND r.application_name IS NOT NULL

      AND r.sampled_at >= statement_timestamp() - since
    GROUP BY r.application_name, r.sampled_at
  ),
  per_app AS (
    SELECT application_name,
           max(waiters_at) AS sessions_peak,
           sum(waiters_at) AS sessions_total,
           max(wait_at)    AS longest_wait,
           count(*)        AS samples,
           min(sampled_at) AS first_at,
           max(sampled_at) AS last_at
    FROM root_wait
    GROUP BY application_name
  ),
  -- Which statements it was the root for. query_id IS NOT NULL because a blocked query has no
  -- query_id, and a NULL in this array is indistinguishable from a gap in the data.
  qids AS (
    SELECT application_name,
           array_agg(DISTINCT query_id ORDER BY query_id) AS ids
    FROM @extschema@.lock_tree_history
    WHERE depth = 0
      AND query_id IS NOT NULL
      AND application_name IS NOT NULL
      AND sampled_at >= statement_timestamp() - since
    GROUP BY application_name
  )
  SELECT t.application_name,
         round(extract(epoch FROM coalesce(t.held, interval '0'))::numeric, 3),
         p.samples,
         t.n_held,
         t.n_dropped,
         p.sessions_peak,
         p.sessions_total,
         p.longest_wait,
         p.first_at,
         p.last_at,
         q.ids
  FROM totals t
  JOIN per_app p ON p.application_name = t.application_name
  LEFT JOIN qids q ON q.application_name = t.application_name
  ORDER BY coalesce(t.held, interval '0') DESC, p.sessions_peak DESC
$$;
