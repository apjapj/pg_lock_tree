/* pg_lock_tree--0.14--0.15.sql
 *
 * Makes the read side stop reading the whole table, and stops replay doing it too.
 *
 * Fifteen window bounds on a stored column used clock_timestamp(), which is VOLATILE, so the planner
 * could not make them index bounds. Every one of them degraded from a seek into a filter over the
 * entire index. Measured on a seven day history of 1.2 million rows, 264 MB:
 *
 *     sampled_at >= clock_timestamp()     - interval '1 hour'
 *       Index Only Scan, Filter, 165740 rows removed,  18.5 ms
 *     sampled_at >= statement_timestamp() - interval '1 hour'
 *       Index Only Scan, Index Cond,                      0.777 ms
 *
 * The cost scaled with the size of the WHOLE history rather than with the window asked for, which is
 * the wrong way round for something a dashboard runs. statement_timestamp() is STABLE, so it becomes
 * an Index Cond, and it is constant for the statement, so nothing is lost by using it.
 *
 * The three clock_timestamp() uses inside the live view are NOT changed: they compute wait_age,
 * xact_age and state_age, which are genuinely per-row instants of "now".
 *
 * lock_tree_replay() found its sample by computing the distance to every row and sorting. 987 ms to
 * replay one sample out of 1.2 million, against 0.556 ms for two index seeks.
 *
 * AND ONE CORRECTNESS FIX, which the performance work exposed rather than caused.
 *
 * lock_tree_duration() and lock_tree_duration_by_application() counted the ROOT among its own
 * waiters, so blocked_sessions_peak and sessions_total came out one too high per sample. A root row
 * carries its own pid in root_pid, so the root-to-waiter join matched the root to itself. Measured: a
 * root with two waiters behind it reported a peak of 3. Fixed by requiring w.depth > 0.
 *
 * It survived two releases because test/17 computed its expected peak with the same self-matching
 * join, so the test agreed with the bug. An expectation derived from the expression under test is not
 * an expectation, and test/19's fixture is built from depth values directly for that reason.
 *
 * NO OTHER BEHAVIOUR CHANGES. Same columns, same types, same results elsewhere. statement_timestamp()
 * and clock_timestamp() differ by microseconds inside one statement, and every other use here is a
 * cutoff for a window rather than a reading of "what time is it".
 *
 * Everything is a replace, so no signature changes and no grants are revoked. Verified by updating a
 * 0.14 database and comparing md5(pg_get_functiondef) for every function against a fresh 0.15
 * install: identical. lock_tree_replay_samples is not in this file because it is unaffected, and
 * lock_tree_replay_text is not here because it calls lock_tree_replay().
 */

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_deadlocks(since interval DEFAULT interval '7 days')
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
    WHERE d.sampled_at >= statement_timestamp() - since
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

--------------------------------------------------------------------------------
-- the wide case: aggregate instead of enumerate
--------------------------------------------------------------------------------

-- A tree of one row per session is the right shape for understanding one incident and the
-- wrong shape for a database with six of them. When sixty sessions are queued behind five
-- roots, the questions an operator actually has are: which root is worst, how many sessions
-- does each one hold up, and is any of them a long chain rather than a flat queue. All three
-- are answerable from one row per root, and none of them require reading sixty lines.
--
-- This is the same aggregate as
--   SELECT root_pid, count(*) FILTER (WHERE depth > 0), max(depth), max(wait_age)
--   FROM lock_tree GROUP BY root_pid
-- given columns, ordering and a text rendering consistent with the rest of the extension.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_prune_alerts(older_than interval DEFAULT interval '1 day')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH gone AS (
    DELETE FROM @extschema@.lock_tree_alert
    WHERE last_notified IS NOT NULL
      AND last_notified < statement_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM gone
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune_alerts(interval) IS
  'Delete alert state last notified on more than the given age ago; returns how many. Only '
  'needed for alert state orphaned by a restart or a retired channel: lock_tree_notify() '
  'already forgets a root as soon as it stops being notable.';


-- How often to sample, given how busy things currently are.
--
-- The history sample is a cron entry, and a cron entry needs a number. Most people pick one by
-- feel and then either pay for it or miss incidents. The honest answer is that it depends on how
-- wide the queue gets, and this says what that is.
--
-- The reasoning, briefly: a queue changes on the scale of seconds, so a sample interval much
-- above a minute will miss short incidents entirely, while an interval far below a few seconds
-- writes the same state repeatedly and grows the table for nothing. The cost of a sample is one
-- row per blocked session, so the interval that matters is the one that keeps a wide queue from
-- dominating the table.

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
    WHERE sampled_at < statement_timestamp() - older_than
    RETURNING 1
  ),
  -- Not counted, but not optional either: a deadlock sample that is never pruned grows by one row
  -- per sample forever, and an unpruned table is how a diagnostic tool becomes an outage.
  dropped AS (
    DELETE FROM @extschema@.lock_tree_deadlock
    WHERE sampled_at < statement_timestamp() - older_than
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

CREATE OR REPLACE PROCEDURE @extschema@.lock_tree_prune_batched(
  older_than interval,
  batch_size integer DEFAULT 10000
)
LANGUAGE plpgsql
AS $proc$
DECLARE
  total bigint := 0;
  took  bigint;
  n     integer;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 THEN
    RAISE EXCEPTION
      'lock_tree_prune_batched() needs batch_size >= 1, got %', coalesce(batch_size::text, 'NULL');
  END IF;

  -- Check for a transaction block before deleting anything.
  --
  -- PostgreSQL exposes no way to ask, so the only way to find out is to COMMIT and see. Doing that
  -- here rather than at the first batch means that calling this inside BEGIN/COMMIT fails having
  -- deleted NOTHING, rather than failing part-way through with half the table gone.
  --
  -- No exception handler around it, deliberately. A plpgsql block with an EXCEPTION clause runs in
  -- a subtransaction, and a COMMIT is never allowed in one, so the check would fail every time
  -- rather than only inside a transaction block. That was the first version, and it refused to work
  -- outside a transaction block too.
  --
  -- The error PostgreSQL raises here is "invalid transaction termination", which does not say why.
  -- The COMMENT ON this procedure says what it means, and the README shows the working call.
  COMMIT;

  LOOP
    -- One batch, chosen by primary key rather than by OFFSET. OFFSET is O(rows skipped), so the
    -- tenth batch walks past every row already deleted and the last one is quadratic in the number
    -- of batches. The index on sampled_at makes this a bounded range scan instead.
    DELETE FROM @extschema@.lock_tree_history h
     WHERE h.ctid IN (
             SELECT c.ctid
             FROM @extschema@.lock_tree_history c
             WHERE c.sampled_at < statement_timestamp() - older_than
             LIMIT batch_size
           );
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    EXIT WHEN n = 0;
    COMMIT;
  END LOOP;

  -- The deadlock samples too, for the same reason lock_tree_prune() does them. Deleted in one
  -- statement rather than in batches, because there is one row per sample rather than one per
  -- blocked session, so it is already a thousand times smaller.
  DELETE FROM @extschema@.lock_tree_deadlock
   WHERE sampled_at < statement_timestamp() - older_than;

  RAISE NOTICE 'lock_tree_prune_batched: removed % history rows older than %', total, older_than;
END
$proc$;

COMMENT ON PROCEDURE @extschema@.lock_tree_prune_batched(interval, integer) IS
  'Prune lock_tree_history in committed batches of batch_size, so no single lock is held for the '
  'whole operation and a long prune can be watched or interrupted without stopping writers. '
  'Removes the deadlock samples too. A procedure, not a function, because only a procedure called '
  'outside a transaction block may COMMIT, and batching without committing between batches still '
  'holds everything. Cannot be called from inside a transaction block. Returns nothing to the '
  'client; the row count is raised as a notice.';


--------------------------------------------------------------------------------
-- knowing when it is over
--------------------------------------------------------------------------------

-- One extra notification per root that HAD notified and has since stopped. Not a new event type on
-- the same meaning: the payload carries 'cleared' in place of 'alerting', so a listener written
-- against 0.6 that ignores unknown payloads is unaffected, and one that switches on the field gets
-- the pair it needs.
--
-- Off by default, deliberately. A resolution notice is a second page, and whether an incident ending
-- is worth waking someone is a property of the rota rather than of the extension. Someone who wants
-- the pager to stay quiet and the dashboard to be exact sets it off; someone whose incident channel
-- is a shared room turns it on and the room learns it is safe.
--
-- A notification that is not accompanied by one saying it started is noise, so the sweep only
-- reports a root it had previously stored. That is the `fired` CTE's whole job: it reads the rows
-- about to be deleted, so a root never alerted is never 'cleared'.

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

COMMENT ON FUNCTION @extschema@.lock_tree_duration(interval) IS
  'Per-query blocking TIME over the sampled history, worst first: for each root query id, the '
  'elapsed time during which it was the thing holding the queue up. Unlike '
  'lock_tree_history_statements(), which counts blocked sessions per sample and therefore doubles '
  'if you sample twice as often over the same incident, this does not move with the sample rate. '
  'Also reports samples seen, gaps counted, gaps discarded, the peak and total number of sessions '
  'this query blocked, the longest single wait it caused, when it was first and last seen, and the '
  'applications it was seen under. A gap counts only where the query was the root at both ends, '
  'and the interval after the last sample is never counted, so this is a lower bound rather than an '
  'estimate. Needs a sampled history, and the samples must be separate statements: a loop of '
  'lock_tree_sample() inside one DO block collapses onto a single sampled_at and records no elapsed '
  'time at all.';


--------------------------------------------------------------------------------
-- blocking TIME per application
--------------------------------------------------------------------------------

-- The number a page actually gets: which application cost the most blocking time.
--
-- NOT lock_tree_duration() grouped by application afterwards, and the difference is not cosmetic. The
-- two disagree whenever an application hands the queue from one statement to another, which is the
-- ordinary case for a connection pool or a batch job running a fixed script.
--
-- Say an app's query 1 is the root at t0 and its query 2 is the root at t1.
--
--   per query      both gaps are DISCARDED: neither query was the root at both ends.
--   per application the gap COUNTS: the application was holding the queue up at both ends, and
--                  from where the application is concerned nothing changed.
--
-- Summing lock_tree_duration() by application would report near zero for an application that spent
-- ten minutes blocking forty sessions, because every individual gap straddled a statement boundary.
-- That is not a rounding error, it is the answer being wrong in the direction that matters.
--
-- So the gap arithmetic is done again on (sampled_at, application_name). Everything else is the same
-- arithmetic as lock_tree_duration(), including the same conservatism: a gap where the APPLICATION
-- was not the root at the far end is discarded rather than apportioned, and the interval after the
-- last sample is never counted.
--
-- An empty application_name is a category of its own and is reported, not filtered. A session that
-- never called SET application_name is one of the findings you are looking for, and hiding it behind
-- a NULL or dropping the row would hide exactly the thing worth noticing.

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

--------------------------------------------------------------------------------
-- per-query blocking time
--------------------------------------------------------------------------------

-- The question that gets a fix merged rather than a workaround. lock_tree_statements() answers
-- it for the chain in front of you; this answers it for the month, from samples already taken.
--
-- "Blocking time" rather than "wait time" because it is the number that maps to a fix. A
-- statement that runs for 900ms and holds nothing up is slow. A statement that runs for 40ms and
-- holds sixty sessions up is the one to fix, and only the blocking figure shows that.
--
-- The unit is the session-sample: one blocked session observed at one sample. That is not the
-- same as wall-clock time, and the difference matters. A session blocked for 60 seconds sampled
-- every 10 seconds contributes six, not sixty. This is deliberate and it is a HIGHER bound on
-- precision, not a lower one on importance: it counts each blocked session once per sample in
-- which it was blocked, so shortening the sample interval increases it proportionally and the
-- ranking between statements is stable while the absolute figure is not. last_seen_at and
-- times_seen let you sanity-check which regime a row is in.
--
-- Only roots carry a query_id, so this is per BLOCKING query rather than per blocked query. That
-- is the useful direction: the question is what to fix, and the blocker is what you can change.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_history_statements(
  since interval DEFAULT interval '7 days'
)
RETURNS TABLE (
  query_id         bigint,
  blocked_sessions bigint,
  samples          bigint,
  first_blocked_at timestamptz,
  last_blocked_at  timestamptz,
  deepest_chain    int,
  longest_wait     interval,
  longest_wait_at  timestamptz,
  applications     text[]
)
LANGUAGE sql STABLE
AS $$
  -- No reference to pg_stat_statements here, deliberately. A SQL function naming a relation that
  -- may not exist fails at CREATE EXTENSION time, which is why lock_tree_statements() is plpgsql
  -- with a guarded dynamic query. This one does not need that machinery: the history carries
  -- query_id, and the totals are pure aggregation over a table this extension owns. Joining the
  -- text back in is one line for whoever has the module loaded, shown in the comment below.
  SELECT h.query_id,
         count(*) FILTER (WHERE h.depth = 0)     AS blocked_sessions,
         count(DISTINCT h.sampled_at)              AS samples,
         min(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.depth),
         max(h.wait_age),
         -- When the worst wait was observed, which is what turns "3m12s" into "at 09:14, during
         -- the month-end run". The wait age alone says how bad, not when to go looking.
         (array_agg(h.sampled_at ORDER BY h.wait_age DESC NULLS LAST))[1],
         array_agg(DISTINCT h.application_name ORDER BY h.application_name)
  FROM @extschema@.lock_tree_history h
  WHERE h.query_id IS NOT NULL
    AND h.sampled_at >= statement_timestamp() - since
  GROUP BY h.query_id
  -- Worst first: the statement to fix is at the top, which is the only ordering anyone wants.
  ORDER BY count(*) FILTER (WHERE h.depth = 0) DESC, max(h.wait_age) DESC NULLS LAST
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_history_statements(interval) IS
  'Per-query blocking time from the sampled history, worst first: for each root query id, how '
  'many blocked sessions it held up across all samples, over how many samples, when first and '
  'last seen, the deepest chain and longest wait under it, when that worst wait happened, and '
  'which applications were involved. The figure counts a blocked session once per sample it was '
  'blocked in, so it rises with the sampling rate; the ranking between statements is what to '
  'read. Needs a sampled history: it answers about the past, not about now. To add the statement '
  'text, join pg_stat_statements on query_id yourself; this function does not reference it, so it '
  'works whether or not that module is loaded.';


--------------------------------------------------------------------------------
-- which samples exist, and what shape each had
--------------------------------------------------------------------------------

-- You cannot ask to replay a sample you do not know about, and the sample instants are the one thing
-- the history does not tell you by looking at it: every row is a session, so a table with 900 rows
-- might be 900 sessions in one sample or 30 sessions in 30 samples. This is the one row per sample.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_replay(as_of timestamptz DEFAULT NULL)
RETURNS TABLE (
  sampled_at       timestamptz,
  root_pid         int,
  root_object      text,
  depth            int,
  pid              int,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text,
  query_id         bigint
)
LANGUAGE sql STABLE
AS $$
  -- The parameter is named as_of and not at because PostgreSQL resolves a bare `at` against the
  -- function's own RETURNS TABLE row type rather than against the argument, and the failure is
  -- "missing FROM-clause entry for table lock_tree_replay". A parameter whose name is not one of the
  -- output columns has no such shadowing.
  --
  -- The distance is computed in its own CTE so the ordering can use it, because PostgreSQL refuses
  -- to let a SELECT DISTINCT order by an expression that is not in its select list. DISTINCT is
  -- unnecessary anyway: ordering by (distance, instant) and taking one row returns a single instant
  -- however many sessions happened to be in it.
  --
  -- coalesce(as_of, clock_timestamp()) is what makes NULL mean "the most recent sample": with no
  -- target, the nearest sample to now is the latest one at or before it.
  -- Two index seeks, not one scan.
  --
  -- The nearest sample to as_of is either the latest one at or before it or the earliest one after
  -- it, and each of those is a single seek on lock_tree_history_sampled_at_idx. The first version
  -- computed the distance for every row and sorted, which is what a window function over the whole
  -- history costs: 987 ms to replay one sample out of 1.2 million rows, against 0.556 ms for
  -- max(sampled_at) under the same index. It was written that way to get around PostgreSQL refusing
  -- to let a SELECT DISTINCT order by an expression outside its select list, and the way round that
  -- restriction was worse than the restriction.
  --
  -- statement_timestamp() and not clock_timestamp() here for the same reason as everywhere else:
  -- this one is a column predicate, and a volatile bound would turn both seeks back into filters.
  -- With as_of NULL it means "up to the start of this statement", which is the most recent sample
  -- for any history written by a sampler.
  WITH target AS (
    SELECT c.sampled_at
    FROM (
      (SELECT max(h.sampled_at) AS sampled_at
         FROM @extschema@.lock_tree_history h
        WHERE h.sampled_at <= coalesce(as_of, statement_timestamp()))
      UNION ALL
      (SELECT min(h.sampled_at)
         FROM @extschema@.lock_tree_history h
        WHERE h.sampled_at > coalesce(as_of, statement_timestamp()))
    ) c
    -- Ties go to the earlier sample. Arbitrary, but at least consistent, and asserted in test/18.
    ORDER BY abs(extract(epoch FROM (c.sampled_at - coalesce(as_of, statement_timestamp())))),
             c.sampled_at
    LIMIT 1
  )
  SELECT h.sampled_at,
         h.root_pid,
         h.root_object,
         h.depth,
         h.pid,
         h.state,
         h.waiting_for,
         h.wait_age,
         h.application_name,
         h.query,
         h.query_id
  FROM @extschema@.lock_tree_history h
  JOIN target t USING (sampled_at)
  -- Same ordering as the live view, minus path. depth then pid stands in for the path order, which
  -- is the same ordering whenever the tree is well formed and is stable when it is not.
  ORDER BY h.root_pid, h.root_object NULLS FIRST, h.depth, h.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_replay(timestamptz) IS
  'The lock tree as it was at a past sample, reconstructed from lock_tree_history. Takes a target '
  'timestamp and uses the sample NEAREST to it, reporting which one in the sampled_at column of every '
  'row; NULL means the most recent. Returns the columns the history recorded: sampled_at, root_pid, '
  'root_object, depth, pid, state, waiting_for, wait_age, application_name, query and query_id. '
  'Nine columns of lock_tree are absent and cannot be supplied, path and blocked_by because the '
  'history stores one row per session rather than the edge between them, and usename, datname, '
  'client_addr, wait_event_type, wait_event, xact_age and state_age because they were never '
  'recorded. waiting_for reads back SCHEMA-QUALIFIED where the live view does not, because '
  'lock_tree_sample() runs with search_path = pg_catalog and regclass cannot resolve unqualified '
  'there. That is deliberate: the live rendering is the path-dependent one, and the history''s is '
  'stable across every sample. See lock_tree_replay_samples for what samples exist.';


--------------------------------------------------------------------------------
-- the same, as something to read
--------------------------------------------------------------------------------

-- Prose during an incident is what lock_tree_text() is for. This is the 3am version of it: the
-- incident is over, you are reading about it, and you want the shape rather than a query.
--
-- Same layout as the live renderer, with the columns the history has. The root line carries its
-- application and query, and each waiter line carries how long it had been waiting, what it wanted,
-- and its own query. The live version also prints xact_age on the root, which is often the most
-- telling number in the whole tree, and replay cannot because it was not recorded.
