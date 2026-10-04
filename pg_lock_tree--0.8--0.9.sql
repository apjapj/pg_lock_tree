/* pg_lock_tree--0.8--0.9.sql
 *
 * One column and one comparison, both inside lock_tree_notify(). No signature changes, so nothing
 * is dropped: the two functions whose bodies changed are replaced in place.
 *
 *   lock_tree_alert.max_waited_at   the longest wait as at the last notification
 *
 * The interesting part is the comparison it enables. A wait grows every second, so asking whether
 * it is longer than last time is true on every sample and would notify sixty times an hour, which
 * is the exact failure mode lock_tree_alert was introduced to prevent. Escalation therefore fires
 * when the longest wait has DOUBLEDE since the last notification, giving 30s, 1m, 2m, 4m, 8m for
 * an incident that never gets wider. Seven notifications for thirty-two minutes, each saying it is
 * roughly twice as bad as the last.
 *
 * It is gated on min_wait being set. An operator who passes min_wait => NULL has said they do not
 * want to be paged on wait age, and honouring that is the difference between a channel people read
 * and a channel people filter.
 *
 * The ADD COLUMN is metadata-only, so it applies instantly whatever the size of the table. Existing
 * rows get an interval of zero, which is the honest answer: the value at their last notification was
 * never recorded. A root whose row predates this upgrade therefore re-notifies once on its next
 * doubling, which is one extra page rather than a missed one.
 */

--------------------------------------------------------------------------------
-- the table
--------------------------------------------------------------------------------

ALTER TABLE @extschema@.lock_tree_alert
  ADD COLUMN IF NOT EXISTS max_waited_at interval NOT NULL DEFAULT interval '0';

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
              -- records a wait for a criterion that does not exist.
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

COMMENT ON FUNCTION @extschema@.lock_tree_notify(text, integer, integer, interval) IS
  'Raise a NOTIFY on a channel when a root blocker is notable, and remember it so the same '
  'incident notifies once rather than on every sample. A root is notable if it meets AT LEAST '
  'ONE of min_blocked, min_depth or min_wait; NULL or 0 switches one off, and at least one '
  'must be set. Once notable, it notifies on onset and then on any of three escalations: more '
  'sessions blocked than ever before, deeper than ever before, or a longest wait that has '
  'doubled since the last notification. The doubling is deliberate: a wait grows continuously, so '
  'comparing it to the previous sample is true every time and would notify on every sample. Age '
  'escalation only applies when min_wait is set, because min_wait => NULL means do not page me on '
  'wait age. Returns how many notifications were raised, so zero is the normal result and the '
  'one worth watching. Payloads are JSON. Wire the channel to a pager yourself: this raises '
  'NOTIFY and nothing more.';

-- Forget alert state that no longer refers to a live session.
--
-- lock_tree_notify() deletes a root's row as soon as that root stops being notable, which is
-- the normal case and needs no help. This is for the abnormal ones: a server that was rebooted
-- mid-incident keeps rows for pids that no longer exist, and a channel name that has been
-- retired keeps rows under it. Small either way, since the table is the size of the current
-- queue, so calling this from the same cron entry as the sample is enough.

COMMENT ON TABLE @extschema@.lock_tree_alert IS
  'What lock_tree_notify() has already alerted on, per channel, per threshold set, per root. '
  'Rows are removed when the root leaves the tree, so a chain that returns alerts again. The '
  'policy column holds the thresholds the row was written under: two different alerting policies '
  'sharing a channel would otherwise clear each other''s state, and each would re-alert on '
  'every alternate sample. Not history: lock_tree_history is that. Prune with '
  'lock_tree_prune_alerts(). root_object is empty for a session root, whose pid already '
  'identifies it, and names the lock held for a prepared-transaction root. The three max_* '
  'columns are high-water marks recorded at the last notification, not the latest sample, which '
  'is what makes a recovery distinguishable from an escalation.';
