/* pg_lock_tree--0.12--0.13.sql
 *
 * Fixes three columns lock_tree_duration() could not get right in 0.12, and adds
 * lock_tree_duration_by_application().
 *
 *   lock_tree_duration()                     same signature, three columns now real
 *   lock_tree_duration_by_application()      new: the aggregation a page actually needs
 *
 * THE BUG. A root's IDENTITY and the waits it CAUSED are on different rows. query_id is on the root
 * row, wait_age is on the waiter's. 0.12 grouped by query_id and read wait_age from those same rows,
 * so:
 *
 *   longest_wait            always NULL, because the rows carrying a query_id carry no wait
 *   blocked_sessions_peak   always 1, because there is exactly one root row per query per sample
 *   sessions_total          that same 1 summed, which repeated the sample count
 *
 * Measured, on a root blocking three sessions across three samples: 0.12 reported
 * blocked_sessions_peak = 1, sessions_total = 3, longest_wait = NULL.
 *
 * One join fixes all three, the root rows of a sample matched to the waiter rows of the SAME sample
 * on root_pid and root_object. The object is part of the match for the reason it is half of
 * lock_tree_alert's primary key: pid 0 is every prepared transaction at once, so matching on pid
 * alone would credit one prepared root's waiters to another.
 *
 * WHY CREATE OR REPLACE AND NOT DROP. The signature and every column type are unchanged, so
 * CREATE OR REPLACE is permitted: the restriction is on changing a return type, not on changing a
 * body. It also keeps the OID, which keeps GRANT EXECUTE ON FUNCTION lock_tree_duration(interval).
 * DROP and CREATE would have silently revoked an operator's grant on a function that did not change
 * shape, which is a worse failure than the bug being fixed.
 *
 * lock_tree_duration_by_application() is not lock_tree_duration() summed by application. Where an
 * application hands the queue from one statement to another, the per-query figures discard every gap
 * that straddles the handover and the per-application figure counts all of them, so the gap
 * arithmetic is done again on (sampled_at, application_name). Summing the per-query numbers would
 * report near zero for an application that blocked forty sessions for ten minutes.
 *
 * Nothing is dropped, no view is re-created and no rewrite lock is taken.
 */

--------------------------------------------------------------------------------
-- three columns that could not be right
--------------------------------------------------------------------------------

-- The corrected lock_tree_duration(). The body is replaced in place; the columns, their types and
-- their documented meanings are unchanged, and three of them now return what the documentation has
-- always said they return.
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
    WHERE h.sampled_at >= clock_timestamp() - since
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
      AND h.sampled_at >= clock_timestamp() - since
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
    WHERE r.depth = 0
      AND r.query_id IS NOT NULL
      AND r.sampled_at >= clock_timestamp() - since
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
      AND sampled_at >= clock_timestamp() - since
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

--------------------------------------------------------------------------------
-- blocking TIME per application
--------------------------------------------------------------------------------

-- Which application cost the most blocking time, which is the number a page gets.
--
-- An empty application_name is reported as its own row rather than filtered. A blocker that never
-- called SET application_name is a finding, and dropping the row would hide the thing worth noticing.
CREATE FUNCTION @extschema@.lock_tree_duration_by_application(since interval DEFAULT interval '7 days')
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
    WHERE h.sampled_at >= clock_timestamp() - since
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
      AND h.sampled_at >= clock_timestamp() - since
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
    WHERE r.depth = 0
      AND r.application_name IS NOT NULL
      AND r.sampled_at >= clock_timestamp() - since
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
      AND sampled_at >= clock_timestamp() - since
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

COMMENT ON FUNCTION @extschema@.lock_tree_duration_by_application(interval) IS
  'Per-APPLICATION blocking TIME over the sampled history, worst first: for each application_name, '
  'the elapsed time during which it was the thing holding the queue up, with the statements it was '
  'root for. Same gap arithmetic and same conservatism as lock_tree_duration(), but keyed on the '
  'application rather than the statement, and the two are not the same figure: a gap in which an '
  'application handed the queue from one statement to another is counted HERE and discarded by '
  'lock_tree_duration(), so summing the per-query figures by application would understate an '
  'application whose statements take turns blocking. Reports peak and total sessions blocked, the '
  'longest single wait caused, and when the application was first and last seen. An empty '
  'application_name is reported as its own row: a blocker that never set one is a finding. Needs a '
  'sampled history whose samples are separate statements.';
