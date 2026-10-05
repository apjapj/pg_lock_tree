/* pg_lock_tree--1.0.1--1.0.2.sql
 *
 * One function is replaced, and only its return text changes.
 *
 * lock_tree_sampling_advice() returned, for a database with nothing blocked and an empty history:
 *
 *   suggested_every  00:00:05
 *   reason           nothing blocked now and nothing in the window: the table stays empty at any
 *                    interval, so sample rarely
 *
 * 00:00:05 is the finest interval the function ever returns, so "so sample rarely" told a reader to
 * do the opposite of what the interval beside it said. Nothing was blocked, so the interval was right:
 * on a quiet database a sample writes no rows at all, and 5 seconds costs one cheap query while
 * catching the next incident in detail. The wording was the defect, and it has been there since 1.0.0.
 *
 * The function is replaced whole because the string is inside its body and a versioned script has no
 * narrower way to change one. The body below is otherwise byte-identical to 1.0.1's, which is the
 * point: scripts/check-upgrade.sh compares the catalog a fresh 1.0.2 install produces against the
 * catalog this path produces, so anything else that moved would fail that check rather than pass
 * unnoticed.
 *
 * look_back is the seventh and last returned column, and it is the one a rewrite is most likely to
 * drop. It is here.
 */

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_sampling_advice(
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
      WHERE h.sampled_at >= statement_timestamp() - since
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
         THEN 'nothing blocked now and nothing in the window: a sample writes nothing here, so 5 seconds'
              || ' costs one cheap query and still catches the next incident in detail'
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
  'window rather than on the queue at this instant. The reason for a quiet database was reworded in '
  '1.0.2: it said "so sample rarely" while returning 00:00:05, the finest interval offered. The '
  'interval was always correct; the wording was not.';
