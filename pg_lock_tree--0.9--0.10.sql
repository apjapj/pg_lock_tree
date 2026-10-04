/* pg_lock_tree--0.9--0.10.sql
 *
 * Deadlocks, and an extension that finally reads its own history.
 *
 *   lock_tree_deadlock                    pg_stat_database.deadlocks, sampled on its own beat
 *   lock_tree_deadlocks(since)            when the counter moved, which the counter cannot say
 *   lock_tree_sample()                    also writes the deadlock row; returns what it always did
 *   lock_tree_prune(older_than)           also prunes deadlock rows; returns what it always did
 *   lock_tree_sampling_advice(since)      takes a window, and sizes on the peak in the history
 *
 * One of those changes a signature and one changes a side effect, both deliberately.
 *
 *   lock_tree_sampling_advice() gains a parameter and three columns, so it is dropped and
 *   recreated: CREATE OR REPLACE FUNCTION refuses a changed OUT list outright, and it returns a
 *   table.
 *
 *   lock_tree_prune() now also deletes from lock_tree_deadlock, and its return value still counts
 *   ONLY the history rows. It has returned a history count since 0.4 and every existing caller reads
 *   that number. At a five second sample interval, counting the deadlock rows as well would inflate
 *   it by a factor of the sample rate for no benefit, and a monitoring job that has been right for
 *   six releases should not start reporting four orders of magnitude more than the table it
 *   watches. One call to remember rather than two is worth the asymmetry. That is a decision, so it
 *   is stated in the function body as well as here.
 *
 * Nothing existing is rewritten and no rewrite lock is taken. The deadlock table is new, so it is
 * created rather than altered.
 */

--------------------------------------------------------------------------------
-- deadlocks
--------------------------------------------------------------------------------

-- pg_stat_database.deadlocks, sampled. It is a cumulative counter with no attribution: it says how
-- many deadlocks this database has had, and nothing at all about which two statements caused them.
-- That is not a gap this extension can close from SQL, because the participants exist only in the
-- server log. What it CAN close is the timing, and timing is what turns a log line into an
-- investigation.
--
-- One row per sample, written whether or not anything is blocked. Deliberately NOT a column on
-- lock_tree_history: that table has rows only while something is blocked, so a deadlock that
-- happened between two samples, or one that cleared before the next tick, would leave nothing
-- behind. Sampling the counter on its own beat is the only way to catch those.
--
-- The table grows by one row per sample, which at a five second interval is 17,000 a day and about
-- 8 MB a month. lock_tree_prune() clears it along with the history, so there is one thing to
-- remember rather than two.
CREATE TABLE @extschema@.lock_tree_deadlock (
  sampled_at     timestamptz NOT NULL DEFAULT statement_timestamp(),
  deadlocks      bigint      NOT NULL,
  -- deadlocks minus the previous sample, floored at zero. Computed once, at insert, and stored, so
  -- that reading the timeline later does not depend on which rows happen to still be present.
  -- Flooring matters because the counter can go BACKWARDS: pg_stat_reset_shared('db') sets it to
  -- zero, and a negative delta in the report would be nonsense.
  delta          bigint      NOT NULL DEFAULT 0,
  -- Set when the counter went backwards, which means the next delta is measured from a new baseline
  -- and the total across the window is not the sum of the deltas. Without this the report would
  -- quietly understate.
  counter_reset  boolean     NOT NULL DEFAULT false,
  PRIMARY KEY (sampled_at)
);

COMMENT ON TABLE @extschema@.lock_tree_deadlock IS
  'pg_stat_database.deadlocks sampled on its own beat, whether or not anything is blocked. Read it '
  'with lock_tree_deadlocks(). It names no participants: the two statements involved are in the '
  'server log, so use the timing here to find the right log entry. Prune it with '
  'lock_tree_prune(), which clears it together with the history.';

-- When deadlocks happened.
--
-- Returns one row per sample at which the counter moved, with how far it moved. The useful output
-- is "three deadlocks, all between 09:00 and 09:15, all on a Monday", which is the shape that
-- points at a deploy or a cron job. The total over the window is on every row so a query does not
-- need a second pass for it.
--
-- Does NOT name the statements, because nothing in SQL does. The recipe for getting them is in the
-- README: enable log_lock_waits, and correlate the DETAIL line against the timestamp column here.
CREATE FUNCTION @extschema@.lock_tree_deadlocks(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  sampled_at    timestamptz,
  deadlocks     bigint,
  delta         bigint,
  counter_reset boolean,
  total_in_window bigint,
  samples_in_window bigint
)
LANGUAGE sql STABLE
AS $$
  -- The window is applied once, in the base, rather than to the returned rows. Applying it after
  -- would let a delta computed against a row outside the window leak in, which is exactly the sort
  -- of off-by-one-window that makes a number wrong without looking wrong.
  WITH base AS (
    SELECT d.sampled_at, d.deadlocks, d.delta, d.counter_reset
    FROM @extschema@.lock_tree_deadlock d
    WHERE d.sampled_at >= clock_timestamp() - since
  ),
  totals AS (
    SELECT sum(delta) FILTER (WHERE NOT counter_reset) AS total,
           count(*)                                     AS samples
    FROM base
  )
  SELECT b.sampled_at,
         b.deadlocks,
         b.delta,
         b.counter_reset,
         t.total,
         t.samples
  FROM base b
  CROSS JOIN totals t
  -- Only the samples where the counter moved. A row per sample is a row per sample, and the rows
  -- where nothing happened are the ones nobody wants.
  WHERE b.delta > 0 OR b.counter_reset
  ORDER BY b.sampled_at
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_deadlocks(interval) IS
  'When pg_stat_database.deadlocks moved, one row per sample where it moved: the cumulative '
  'counter, how far it moved, whether the counter was reset since, and the total across the window. '
  'Names no participants, because nothing in SQL does; the two statements are in the server log and '
  'the timestamp here is how you find the right entry. Empty means no deadlocks were sampled, which '
  'is not quite the same as none happening: one between two samples is invisible, since the counter '
  'can only be read at the instants you read it.';

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
  -- Two independent inserts, and BOTH run even though only one is counted. A data-modifying CTE is
  -- executed exactly once whether or not anything selects from it, which is the property that lets
  -- the deadlock sample be written here without changing what this function returns.
  WITH observed AS (
    SELECT d.deadlocks
    FROM pg_stat_database d
    WHERE d.datname = current_database()
  ),
  previous AS (
    SELECT p.deadlocks
    FROM @extschema@.lock_tree_deadlock p
    ORDER BY p.sampled_at DESC
    LIMIT 1
  ),
  recorded AS (
    INSERT INTO @extschema@.lock_tree_deadlock
      (sampled_at, deadlocks, delta, counter_reset)
    SELECT statement_timestamp(),
           o.deadlocks,
           -- Floored, because pg_stat_reset_shared('db') sets the counter to zero and a negative
           -- delta would be nonsense. counter_reset records that it happened so the report can say
           -- the window total is not the sum of the deltas.
           greatest(o.deadlocks - coalesce(p.deadlocks, o.deadlocks), 0),
           p.deadlocks IS NOT NULL AND o.deadlocks < p.deadlocks
    FROM observed o
    LEFT JOIN previous p ON true
    ON CONFLICT (sampled_at) DO UPDATE
      SET deadlocks     = EXCLUDED.deadlocks,
          delta         = EXCLUDED.delta,
          counter_reset = EXCLUDED.counter_reset
    RETURNING 1
  ),
  written AS (
    INSERT INTO @extschema@.lock_tree_history
      (sampled_at, root_pid, depth, pid, state, waiting_for,
       wait_age, application_name, query, root_object, query_id)
    SELECT statement_timestamp(), lt.root_pid, lt.depth, lt.pid, lt.state, lt.waiting_for,
           lt.wait_age, lt.application_name, left(coalesce(lt.query, ''), 300), lt.root_object,
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

COMMENT ON FUNCTION @extschema@.lock_tree_sample() IS
  'Take one snapshot of the current lock tree into lock_tree_history. Returns the number of '
  'rows written, which is 0 when nothing is blocked. Schedule it; nothing calls it for you.';

-- Drop history older than a given age, returning how many rows went.
--
-- This exists because the table grows without bound otherwise: rows are only ever added,
-- and a wide queue at one sample a minute is 60 rows a minute for every session in it.
-- Pruning is a policy choice, so it is a parameter and not a scheduled job. A sensible
-- starting point is a day, or a week if you are chasing a rare one.
--
-- DELETE rather than TRUNCATE because TRUNCATE would take the whole table including rows
-- you wanted to keep.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_prune(older_than interval)
RETURNS bigint
LANGUAGE sql
AS $$
  -- RETURNING 1 for the same reason as above: without it the CTE cannot be counted.
  --
  -- The deadlock samples are pruned by the same call, and the return value deliberately counts only
  -- the HISTORY rows. That is the number every existing caller reads, and it is the number that
  -- tells you whether the table you care about shrank. Including the deadlock rows would change the
  -- meaning of a function that has returned a history count since 0.4, and at a five second sample
  -- interval it would inflate the figure by a factor of the sample rate for no benefit. One call to
  -- remember rather than two is worth the asymmetry, and this comment is where that lives.
  WITH pruned AS (
    DELETE FROM @extschema@.lock_tree_history
    WHERE sampled_at < clock_timestamp() - older_than
    RETURNING 1
  ),
  -- Not counted, but not optional either: a deadlock sample that is never pruned grows by one row
  -- per sample forever, and an unpruned table is how a diagnostic tool becomes an outage.
  dropped AS (
    DELETE FROM @extschema@.lock_tree_deadlock
    WHERE sampled_at < clock_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM pruned
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune(interval) IS
  'Delete lock_tree_history rows older than the given age; returns how many. Call it on the '
  'same schedule as the sample. The table grows by one row per blocked session per sample '
  'otherwise, with nothing to stop it.';

-- The question this whole section exists to answer: "it was hanging earlier, what was it?"
--
-- An incident is a run of samples with no gap longer than max_gap between them. The default
-- of five minutes suits a sample every ten seconds or so, and is a parameter because the
-- right answer depends on how often you sample: too small and one incident splits into
-- several, too large and two incidents merge into one.
--
-- peak_sessions is the high-water mark of sessions blocked at any sample, not the sum, since
-- a session counted at four samples was not four sessions.

DROP FUNCTION @extschema@.lock_tree_sampling_advice();

CREATE FUNCTION @extschema@.lock_tree_sampling_advice(
  since interval DEFAULT interval '7 days'
)
RETURNS TABLE (
  blocked_sessions bigint,
  roots            bigint,
  suggested_every  interval,
  reason           text,
  observed_peak    bigint,
  live_blocked     bigint,
  look_back        interval
)
LANGUAGE sql STABLE
AS $$
  -- Read from the history, not from the instant, which is the whole change in 0.10.
  --
  -- Through 0.9 this reported advice from whatever happened to be true at the moment it was called.
  -- A cron entry on a quiet Sunday at 3am therefore saw zero sessions blocked and recommended the
  -- finest interval, on a database that spends every weekday morning with four hundred of them
  -- waiting. The advice was not wrong about the instant; it was answering the wrong question. The
  -- question is what the table has to carry, and the table's size is set by the peaks.
  --
  -- max(observed_peak, live_blocked) rather than observed_peak alone: the peak cannot know about a
  -- queue that started after the last sample, and telling someone to widen their interval while
  -- their queue is growing is exactly the wrong advice at the wrong moment.
  WITH seen AS (
    SELECT coalesce(max(per_sample.sessions), 0) AS peak
    FROM (
      SELECT count(*)::bigint AS sessions
      FROM @extschema@.lock_tree_history h
      WHERE h.sampled_at >= clock_timestamp() - since
      GROUP BY h.sampled_at
    ) per_sample
  )
  SELECT greatest(seen.peak, s.blocked_sessions),
         s.roots,
         -- Three bands, chosen on cost rather than taste. Under 10 sessions a sample is cheap
         -- and detail is worth having. Under 100 it is 10 times the storage and a 10 second
         -- interval still catches everything that lasts longer than a query. Past that the
         -- table is the dominant cost and 30 seconds is enough to characterise an incident.
         CASE WHEN greatest(seen.peak, s.blocked_sessions) < 10  THEN interval '5 seconds'
              WHEN greatest(seen.peak, s.blocked_sessions) < 100 THEN interval '10 seconds'
              ELSE interval '30 seconds' END,
         CASE WHEN greatest(seen.peak, s.blocked_sessions) = 0
              THEN 'nothing blocked now and nothing in the window: the table stays empty at any interval, so sample rarely'
              WHEN seen.peak > s.blocked_sessions
              THEN 'quiet now, but ' || seen.peak || ' sessions were waiting at the peak in this window, so sized for that rather than for now'
              WHEN greatest(seen.peak, s.blocked_sessions) < 10
              THEN 'few sessions blocked: cheap to sample finely, so keep the detail'
              WHEN greatest(seen.peak, s.blocked_sessions) < 100
              THEN 'a busy queue: 10 seconds catches anything that lasts, at a tenth the storage'
              ELSE 'a wide queue: each sample writes a row per blocked session, so widen the interval'
         END,
         seen.peak,
         s.blocked_sessions,
         -- Named look_back rather than window: WINDOW is a reserved word, so a column called window
         -- has to be quoted at every use and in every example that reads it.
         since
  FROM @extschema@.lock_tree_summary() s
  CROSS JOIN seen
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sampling_advice(interval) IS
  'A suggested interval for lock_tree_sample(), and why. Sized on the widest queue seen in the '
  'window rather than on the queue at this instant, because a cron entry that runs on a quiet '
  'Sunday at 3am would otherwise size a weekday-morning database for Sunday. The figure used is '
  'the greater of the two, so a queue that started after the last sample is not ignored. Returns '
  'that figure as blocked_sessions, and also observed_peak, live_blocked and look_back, so the '
  'advice can be traced back to what it was based on.';

--------------------------------------------------------------------------------
-- history: what the tree looked like while you were not looking
--------------------------------------------------------------------------------

-- Everything above describes the present. That is a real limit: an incident is usually
-- discovered after it has ended, by a slow query, a timeout, or a user reporting that
-- "it was hanging earlier". By then pg_stat_activity has moved on and the tree is empty.
-- This is the part that closes that gap: sample on a schedule, keep it, and segment the
-- result into incidents you can read later.
--
-- Nothing here runs by itself. lock_tree_sample() takes exactly one snapshot and is the
-- only thing that writes. Until you schedule it, the table stays empty and this extension
-- behaves exactly as 0.3 did.
--
-- The extension still needs no shared_preload_libraries. pg_cron is a convenient scheduler
-- and nothing more: any scheduler works, including a cron job on the database host calling
-- psql. If you do use pg_cron, see INSTALL.md, because it needs preloading and that is a
-- server change rather than an extension one.

-- sampled_at is statement_timestamp(), and getting that right took two attempts worth
-- recording. clock_timestamp() is volatile and is therefore evaluated once per ROW, so the
-- two sessions in a two-session chain landed microseconds apart. Grouping by sampled_at
-- then yields one group per session instead of one per sample, which silently reduces
-- peak_sessions to 1 for every incident ever recorded. now() has the opposite problem: it
-- is the transaction timestamp, so every row across every sample in one transaction shares
-- an instant and the whole thing collapses to one point. statement_timestamp() is stable
-- for the duration of the one statement that takes the sample, and moves between samples,
-- which is exactly the grain the grouping below needs.
--
-- The table holds one row per session per sample, not one row per sample: the shape of the
-- chain is the thing worth keeping, and a single row per sample would throw away depth,
-- path and wait age. query is truncated to 300 characters because the history of a wide
-- queue is mostly the same few long queries repeated, and unbounded text turns a sampling
-- table into a disk problem.
