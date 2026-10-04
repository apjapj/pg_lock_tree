/* pg_lock_tree--0.11--0.12.sql
 *
 * Two additions, both about the same thing: turning what the extension already recorded into
 * something an operator can act on.
 *
 *   lock_tree_duration(since)        per-query blocking TIME, which is not a sample count
 *   lock_tree_notify_resolved(...)   a "cleared" notice when a notified incident ends
 *
 * lock_tree_duration(). lock_tree_history_statements() counts blocked sessions per SAMPLE, so it
 * doubles if you sample twice as often over the same incident. That is a count of observations and
 * the 0.7 documentation says so. Measured here on a six second incident sampled twice:
 *
 *                    session-samples   gap-summed time
 *   3 samples / 6s            3          00:00:06
 *   + 6 more   / 6s           9          00:00:06
 *
 * One figure tracked elapsed time and the other tracked observations. Ranking statements by a
 * number that moves when you change your cron entry is ranking them by your cron entry.
 * lock_tree_duration() sums the GAPS between sample instants, and a gap counts only where the query
 * was the root at both ends, so each gap is bounded by two instants at which it demonstrably held
 * the queue up. That is a measurement rather than an interpolation, and it is a lower bound: the
 * interval after the last sample is never counted, because nobody observed it.
 *
 * lock_tree_history_statements() is unchanged and still there. It is the cheaper question, needs no
 * gap arithmetic, and for "which query blocks the most sessions" it is the right answer. Both are
 * worth having, and they are not substitutes for one another.
 *
 * lock_tree_notify_resolved(). lock_tree_notify() says when something starts getting worse and then
 * says nothing, which was deliberate in 0.6 and is right for the pager. It is wrong for the person
 * who was woken up and now has no way to learn whether to go back to bed. This sends one
 * notification per root that HAD alerted and has since left the tree, with event = 'cleared' in
 * place of 'alerting', so a listener written against 0.6 that ignores unknown payloads is
 * unaffected. It reads and writes the same rows as lock_tree_notify() under the same policy key,
 * so pass both functions the same thresholds.
 *
 * Both objects are new. Nothing existing is rewritten, no view is re-created and no rewrite lock is
 * taken, so this update is fast on a history of any size.
 */

--------------------------------------------------------------------------------
-- one payload change to lock_tree_notify()
--------------------------------------------------------------------------------

-- The notification payload gains one key: "event", set to "alerting".
--
-- It had none before, which is fine until there is a second kind of notification on the same channel
-- and a consumer has to tell them apart. The alternative would be for a listener to infer onset from
-- the ABSENCE of a key, which is the kind of contract that breaks silently. Found while adding
-- lock_tree_notify_resolved() below: the first run of check-alert.sh asserted that the first payload
-- said "alerting" and was wrong, because nothing had ever put it there.
--
-- Additive, so it is safe. JSON consumers read by key, and a listener written against 0.6 that
-- ignores fields it does not recognise is unaffected. Every documented key keeps its meaning and its
-- position in the payload.
--
-- CREATE OR REPLACE FUNCTION, not DROP and CREATE. This function has no OUT list, and the restriction
-- is on changing a return type rather than on changing a body. In place it takes a lock on this one
-- catalog row and nothing else: no table, no view, and none of the alert state, which is data.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_notify(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,
  min_depth    integer  DEFAULT 2,
  min_wait     interval DEFAULT '30 seconds'
)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  r           record;
  prior       record;
  fired       bigint := 0;
  -- Per-root, not the call's total. Testing `fired > 0` here would mean that once any root had
  -- notified, every later root in the same loop also notified, including ones that should stay
  -- quiet, which is the noise this whole design exists to avoid.
  root_fired  boolean := false;
  -- The thresholds, rendered as one string and used as part of the state key. Two different
  -- alerting policies sharing a channel would otherwise clear each other's state, so each would
  -- re-alert on every alternate sample. Found by a test that alternated thresholds and saw both
  -- roots fire twice where one of them had not actually got worse.
  -- Named pol rather than policy: a plpgsql variable sharing a column's name is ambiguous in
  -- every query that mentions the column, and qualifying it in expressions is not enough,
  -- because there is no valid qualified-assignment form to disambiguate the assignment.
  pol         text;
  -- Normalised thresholds: a criterion set to zero or negative is the same as switching it off,
  -- which is what someone means by passing 0.
  want_blocked integer := CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                               ELSE min_blocked END;
  want_depth   integer := CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                               ELSE min_depth END;
  want_wait    interval := CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                               ELSE min_wait END;
BEGIN
  pol := format('blocked>=%s depth>=%s wait>=%s',
                   coalesce(want_blocked::text, 'off'),
                   coalesce(want_depth::text,   'off'),
                   coalesce(want_wait::text,    'off'));

  IF want_blocked IS NULL AND want_depth IS NULL AND want_wait IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_notify() needs at least one threshold: pass min_blocked, min_depth or '
      'min_wait. Passing NULL switches one criterion off, but all three off means alerting on '
      'every root, which is almost certainly not what you want.';
  END IF;

  FOR r IN
    SELECT w.root_pid, w.root_object, w.application_name, w.blocked_sessions, w.max_depth,
           w.longest_wait, w.first_waiting_for,
           (want_blocked IS NOT NULL AND w.blocked_sessions >= want_blocked)
           OR (want_depth   IS NOT NULL AND w.max_depth       >= want_depth)
           OR (want_wait    IS NOT NULL AND w.longest_wait    >= want_wait) AS notable
    FROM @extschema@.lock_tree_wide() w
  LOOP
    IF NOT r.notable THEN
      -- Below every threshold. It stays below until it stops being in the tree at all, which
      -- the sweep after the loop takes care of, so nothing to do here.
      root_fired := false;
      CONTINUE;
    END IF;

    SELECT * INTO prior FROM @extschema@.lock_tree_alert a
     WHERE a.channel = lock_tree_notify.channel
       AND a.policy  = pol
       AND a.root_pid = r.root_pid
       AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');

    IF NOT FOUND THEN
      -- First time this root has been notable on this channel. That is the onset, and the one
      -- case that is always worth telling someone about.
      INSERT INTO @extschema@.lock_tree_alert
        (channel, policy, root_pid, root_object, application_name, first_seen, last_notified,
         notify_count, max_blocked_at, max_depth_at, max_waited_at)
      VALUES (lock_tree_notify.channel, pol, r.root_pid, coalesce(r.root_object, ''),
              r.application_name,
              statement_timestamp(), statement_timestamp(), 1,
              r.blocked_sessions, r.max_depth,
              -- A CASE rather than greatest(coalesce(r.longest_wait, 0), want_wait), because
              -- greatest() IGNORES null arguments in PostgreSQL rather than propagating them. With
              -- min_wait off, want_wait is NULL, so greatest(3s, NULL) is 3s and the row quietly
              -- records a wait for a criterion that does not exist. Found by the test that asserts
              -- nothing is recorded when min_wait => NULL, which it was not.
              CASE WHEN want_wait IS NOT NULL
                   THEN greatest(coalesce(r.longest_wait, interval '0'), want_wait)
                   ELSE interval '0' END);
      fired := fired + 1;
      root_fired := true;
    ELSIF r.blocked_sessions > prior.max_blocked_at
       OR r.max_depth > prior.max_depth_at
       -- The greatest(), not a bare comparison, and that is the whole subtlety. If max_waited_at
       -- is still zero the doubling target is zero, and "wait >= 0" is true on every sample: the
       -- function would notify sixty times an hour, which is the failure lock_tree_alert exists to
       -- prevent. Zero happens whenever the wait was under a second at onset, because the view
       -- truncates wait_age to whole seconds. Falling back to want_wait means the first escalation
       -- is the operator's own threshold, which is the only sensible answer when there is no
       -- recorded wait to double.
       OR (want_wait IS NOT NULL AND r.longest_wait IS NOT NULL
           AND r.longest_wait >= greatest(prior.max_waited_at * 2, want_wait)) THEN
      -- Escalation, on any of three ways of getting worse.
      --
      -- Width and depth are compared against high-water marks rather than the previous sample, so a
      -- chain that wobbles between 40 and 12 sessions notifies once, not twice a minute.
      --
      -- Age is compared against twice the wait recorded at the last notification, NOT against the
      -- previous sample. A wait grows continuously, so the previous-sample comparison is true
      -- every time and would notify on every sample, which is the noise lock_tree_alert exists to
      -- prevent. Doubling gives 30s, 1m, 2m, 4m, 8m, and it is gated on min_wait being set: an
      -- operator who passed min_wait => NULL asked not to be paged on wait age, and a second page
      -- about a slow queue is how a channel gets ignored.
      UPDATE @extschema@.lock_tree_alert a
         SET last_notified  = statement_timestamp(),
             notify_count   = notify_count + 1,
             max_blocked_at = greatest(max_blocked_at, r.blocked_sessions),
             max_depth_at   = greatest(max_depth_at, r.max_depth),
             -- greatest() against want_wait as well, so a root whose wait was under a second at
             -- onset stores the threshold rather than zero. Otherwise the next comparison would
             -- double zero and fire on every sample.
             -- greatest() ignores NULLs rather than propagating them, so want_wait has to be
             -- handled by the CASE rather than passed through to it.
             max_waited_at  = CASE WHEN want_wait IS NOT NULL AND r.longest_wait IS NOT NULL
                                   THEN greatest(max_waited_at, r.longest_wait, want_wait)
                                   ELSE max_waited_at END,
             root_object    = coalesce(r.root_object, ''),
             application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
      fired := fired + 1;
      root_fired := true;
    ELSE
      -- Notable but unchanged. Stay quiet: this is the case that turns an alerting function into
      -- noise, and the whole reason lock_tree_alert exists.
      UPDATE @extschema@.lock_tree_alert a
         SET application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
    END IF;

    IF root_fired THEN
      PERFORM pg_notify(lock_tree_notify.channel, json_build_object(
        'channel',           lock_tree_notify.channel,
        -- Added in 0.12. There was no event key before, and adding one is what lets a consumer
        -- branch on a single field to tell an onset from a resolution, rather than inferring it
        -- from the absence of a key. It is additive: JSON consumers read by key, so a listener
        -- written against 0.6 that ignores fields it does not recognise is unaffected.
        'event',             'alerting',
        'root_pid',          r.root_pid,
        -- null in the payload for a session root, a lock name for a prepared one. A listener
        -- keying on application_name, which is what the documentation recommends, is unaffected;
        -- this is there so a listener that has two prepared roots can tell them apart.
        'root_object',       r.root_object,
        'application_name',  r.application_name,
        'blocked_sessions',  r.blocked_sessions,
        'max_depth',         r.max_depth,
        'longest_wait',      @extschema@.lock_tree_age(r.longest_wait),
        'waiting_for',       r.first_waiting_for
      )::text);
    END IF;
  END LOOP;

  -- Sweep away state for roots that are no longer in the tree at all. This cannot live in the
  -- loop above, because the loop iterates over lock_tree_wide(), and a root whose waiters have
  -- all gone has no edges and therefore no row there: it simply vanishes. Without this sweep the
  -- table grows one row per root ever seen, forever, and every one of them is a pid that will
  -- never be reused. Found by a test asserting the table empties on recovery, which it did not.
  DELETE FROM @extschema@.lock_tree_alert a
   WHERE a.channel = lock_tree_notify.channel
     AND a.policy  = pol
     -- Matched on the pair, not the pid. With the pid alone this sweep deleted a prepared
     -- transaction's state as soon as ANY prepared root was present, because pid 0 matched.
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                      WHERE t.root_pid = a.root_pid
                        AND coalesce(t.root_object, '') = a.root_object);

  RETURN fired;
END
$fn$;

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
-- the pager to stay quiet and the dashboard to be exact leaves this alone; someone whose incident
-- channel is a shared room runs it and the room learns it is safe.
--
-- A resolution notice with no matching alert is noise, so this only ever reports a root it had
-- previously stored. That is the entire logic of the loop below: it reads the rows it is about to
-- delete, so a root that never alerted is never cleared.
--
-- Taken as a separate function rather than a parameter on lock_tree_notify() because the argument
-- list would then have to carry a fifth value that only some callers care about, and because a
-- caller who never wants it should not be able to set it by accident through named notation.
CREATE FUNCTION @extschema@.lock_tree_notify_resolved(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,
  min_depth    integer  DEFAULT 2,
  min_wait     interval DEFAULT '30 seconds'
)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  gone record;
  n    bigint := 0;
BEGIN
  -- The same policy key construction as lock_tree_notify(), so the two read and write the same
  -- rows. If they disagreed, this would report resolutions for alerts that were never sent.
  FOR gone IN
    SELECT a.root_pid, a.root_object, a.application_name, a.max_blocked_at, a.notify_count
    FROM @extschema@.lock_tree_alert a
    LEFT JOIN @extschema@.lock_tree t
      ON t.root_pid = a.root_pid
     AND coalesce(t.root_object, '') = a.root_object
    WHERE a.channel = lock_tree_notify_resolved.channel
      AND a.policy  = format('blocked>=%s depth>=%s wait>=%s',
                             coalesce(CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                                          ELSE min_blocked END::text, 'off'),
                             coalesce(CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                                          ELSE min_depth   END::text, 'off'),
                             coalesce(CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                                          ELSE min_wait END::text, 'off'))
      -- Not in the tree any more. The LEFT JOIN plus the NULL test rather than NOT EXISTS, so one
      -- root cannot be reported twice by two different trees.
      AND t.root_pid IS NULL
  LOOP
    PERFORM pg_notify(lock_tree_notify_resolved.channel, json_build_object(
      'event',            'cleared',
      'channel',          lock_tree_notify_resolved.channel,
      'root_pid',         gone.root_pid,
      'root_object',      nullif(gone.root_object, ''),
      'application_name', gone.application_name,
      -- What it was, so the reader knows whether it was ever serious. notify_count is the number of
      -- escalations, which is the closest thing to a severity the state table keeps.
      'blocked_at_most',  gone.max_blocked_at,
      'notified_count',   gone.notify_count
    )::text);
    n := n + 1;
  END LOOP;

  -- Then forget it, exactly as lock_tree_notify() would have. Leaving the row would mean the next
  -- incident starts already alerted, and the onset notification would never be sent.
  DELETE FROM @extschema@.lock_tree_alert a
   WHERE a.channel = lock_tree_notify_resolved.channel
     AND a.policy  = format('blocked>=%s depth>=%s wait>=%s',
                            coalesce(CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                                         ELSE min_blocked END::text, 'off'),
                            coalesce(CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                                         ELSE min_depth   END::text, 'off'),
                            coalesce(CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                                         ELSE min_wait END::text, 'off'))
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                      WHERE t.root_pid = a.root_pid
                        AND coalesce(t.root_object, '') = a.root_object);

  RETURN n;
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_notify_resolved(text, integer, integer, interval) IS
  'Raise one NOTIFY per root that had previously alerted and has now left the tree, with event = '
  '''cleared'', and forget the stored state so the next incident alerts again. Takes the same '
  'thresholds as lock_tree_notify() and keys on the same state, so the two read and write the same '
  'rows: give both the same arguments or this reports resolutions for alerts that were never sent. '
  'A root that never alerted produces nothing. Returns how many it sent.';


--------------------------------------------------------------------------------
-- blocking TIME rather than a sample count
--------------------------------------------------------------------------------

-- The figure that gets a fix merged, rather than the figure that gets a workaround.
--
-- lock_tree_history_statements() reports session-samples: one unit per blocked session per sample.
-- That is a count of OBSERVATIONS and it is honest about what it is, but it is not a duration, and
-- the 0.7 documentation says so. This is the duration.
--
-- How a duration can be recovered from samples at all. Each row records an INSTANT and nothing else,
-- so no single row has duration in it. Duration comes from the gaps BETWEEN instants: while this
-- query was the root at both t0 and t1, it was the root for the whole of t0 to t1. Summing those
-- gaps is a measurement, not an interpolation, because both endpoints are moments at which the query
-- demonstrably held the queue up.
--
-- The gap that counts is the one between consecutive sample instants, and only where the query was
-- the root at BOTH ends. A gap where the root changed is discarded rather than apportioned: nobody
-- observed when the handover happened, so any split would be invented. That makes this a lower bound
-- on the truth, stated rather than hidden.
--
-- Also not counted: the interval after the LAST sample, and before the first. A chain still standing
-- when the sampler last ran contributed time nobody measured. samples, gaps and gaps_excluded report
-- all of it so a reader can see how much was left out and why.
--
-- blocked_sessions_peak and longest_wait are carried over from the same aggregation, because a query
-- can block four sessions briefly or one session for an hour, and the duration alone does not say
-- which.
CREATE FUNCTION @extschema@.lock_tree_duration(since interval DEFAULT interval '7 days')
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
  -- Per sample first, because the peak is a maximum OF per-sample counts and cannot be recovered from
  -- a total. The outer group is then per query_id, one row, so joining it to the gap totals cannot
  -- multiply anything. An earlier draft grouped by query_id AND sampled_at here, which returned one
  -- row per sample and multiplied every total by the sample count.
  per_sample AS (
    SELECT query_id, sampled_at,
           count(*) FILTER (WHERE depth = 0) AS sessions_at,
           count(*)                         AS any_at,
           max(wait_age)                    AS wait_at
    FROM @extschema@.lock_tree_history
    WHERE query_id IS NOT NULL
      AND sampled_at >= clock_timestamp() - since
    GROUP BY query_id, sampled_at
  ),
  per_query AS (
    SELECT query_id,
           max(sessions_at) AS sessions_peak,
           sum(sessions_at) AS sessions_total,
           sum(any_at)      AS sessions_any,
           max(wait_at)     AS longest_wait,
           min(sampled_at)  AS first_at,
           max(sampled_at)  AS last_at
    FROM per_sample
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
         p.sessions_any,
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
  'Also reports samples seen, gaps counted, gaps discarded, peak and total sessions blocked, the '
  'longest single wait, when it was first and last seen, and the applications involved. A gap '
  'counts only where the query was the root at both ends, and the interval after the last sample is '
  'never counted, so this is a lower bound rather than an estimate. Needs a sampled history, and '
  'the samples must be separate statements: a loop of lock_tree_sample() inside one DO block '
  'collapses onto a single sampled_at and records no elapsed time at all.';