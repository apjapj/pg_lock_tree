-- pg_lock_tree 1.1.16 -> 1.2.0
--
-- Adds the two escalation keys of the shared pg_incident_watch alert contract to both NOTIFY
-- payloads: `level` and `previous_level`. They are additive, so nothing a consumer built against
-- 1.1.16 can break, and no existing key is removed, renamed or re-valued. No signature, returned
-- column or table changes.
--
--   lock_tree_notify()          the alerting payload gains `level` and `previous_level`.
--                               `level` is the notify_count read AFTER the increment for this
--                               notification: 1 at onset, prior.notify_count + 1 at escalation.
--                               `previous_level` is that number minus one: null at onset, the
--                               previous level at each escalation.
--   lock_tree_notify_resolved() the cleared payload gains `level`, the last level reached, which is
--                               the swept row's notify_count. `previous_level` is absent there, not
--                               present and null: a cleared payload has no escalation.
--
-- Both functions change by CREATE OR REPLACE, never DROP, so grants and COMMENTs are kept, as
-- pg_lock_tree--1.1.15--1.1.16.sql explains. Bodies are lifted verbatim from pg_lock_tree--1.2.0.sql.
--
-- The meaning of the two keys is pinned by the family contract in ALERTS.md, in the
-- pg_incident_watch umbrella repository, so the tools cannot drift. `level` counts how far an
-- incident has climbed, one step per notification; a listener tells an onset from an escalation on
-- the same `alerting` event by reading `previous_level`. Escalation is still not a third event:
-- this extension keeps sending `alerting` for both onset and escalation.

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
  -- The alert's level and the level it replaced, per the shared pg_incident_watch contract. Both
  -- are set in the onset and escalation branches below, which are the only branches that send a
  -- payload. `level` is the notify_count read AFTER the increment: 1 at onset and
  -- prior.notify_count + 1 at escalation. `previous_level` is that number minus one, so it is null
  -- at onset and the previous level at each escalation. An off-by-one here is invisible in prose,
  -- which is why the contract fixes the increment point and ALERTS.md says so.
  new_level   integer;
  prev_level  integer;
BEGIN
  pol := @extschema@.lock_tree_policy_key(min_blocked, min_depth, min_wait);

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
    -- Reset for EVERY root, at the top. Until 1.1.15 it was reset only in the branch below, so a
    -- root that was notable but unchanged inherited true from an earlier root that fired, and was
    -- notified again with the payload it already had while the return value said it had not been.
    -- Measured with two roots, one escalating: returned 1, delivered 2. scripts/check-alert.sh
    -- asserts the delivered count, which is the only place the difference is visible.
    root_fired := false;
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
      -- The onset is level 1: the row was inserted with notify_count = 1. There is no previous
      -- level, so the key is present with a null rather than omitted.
      new_level  := 1;
      prev_level := NULL;
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
      -- The escalation reads the level after the increment the UPDATE just made, so it is the
      -- prior row's count plus one, and the previous level is that prior count. `prior` holds the
      -- row as it was before the UPDATE.
      new_level  := prior.notify_count + 1;
      prev_level := prior.notify_count;
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
        -- The three keys added in 1.1.11 for the shared alert contract in the pg_incident_watch
        -- umbrella, which is where the reasoning and the other two tools' commitments live. All
        -- three are additive, so a consumer written against 1.1.10 that ignores keys it does not
        -- recognise is unaffected, which is this project's existing rule for payload keys.
        --
        -- `tool` is the whole reason they exist: until now the only thing identifying which
        -- extension sent a message was the channel name, so a listener on several tools had to
        -- hard-code a mapping outside the payload.
        'tool',              'pg_lock_tree',
        -- The alert's identity, stable for the life of this incident. A prepared transaction has no
        -- session to name, so its lock name is the only identity available and the pid alone would
        -- collide with any live session; the same pair is what keys lock_tree_alert.
        'subject',           coalesce(nullif(r.root_object, ''), 'pid ' || r.root_pid),
        -- The alert is about now, not about a sampled instant: lock_tree_wide() reports the live
        -- tree and carries no timestamp, so statement_timestamp() is the honest value here.
        'sampled_at',        statement_timestamp(),
        'channel',           lock_tree_notify.channel,
        -- Added in 0.12. There was no event key before, and adding one is what lets a consumer
        -- branch on a single field to tell an onset from a resolution, rather than inferring it
        -- from the absence of a key. It is additive: JSON consumers read by key, so a listener
        -- written against 0.6 that ignores fields it does not recognise is unaffected.
        'event',             'alerting',
        -- Added in 1.2.0, the two escalation keys of the shared contract. `level` is this
        -- incident's count of notifications read AFTER the increment for this one. `previous_level`
        -- is null at onset and the prior level at each escalation, which is how a listener tells
        -- the two apart on the same event, since escalation is not a third event value.
        'level',             new_level,
        'previous_level',    prev_level,
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

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_notify_resolved(
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
  -- One statement decides and forgets, and its RETURNING is what is reported. Until 1.1.16 a SELECT
  -- chose what to report and a separate DELETE chose what to forget, each reading the live tree, so a
  -- root that came back between the two was reported cleared and kept: the next lock_tree_notify()
  -- found its row, treated it as already alerted, and sent nothing for an incident still under way.
  -- Measured by slowing pg_notify while a session that was already connected started waiting on the
  -- same root. Now a root is reported cleared exactly when its row is deleted, and never otherwise.
  FOR gone IN
    DELETE FROM @extschema@.lock_tree_alert a
     WHERE a.channel = lock_tree_notify_resolved.channel
       AND a.policy  = @extschema@.lock_tree_policy_key(min_blocked, min_depth, min_wait)
       AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                        WHERE t.root_pid = a.root_pid
                          AND coalesce(t.root_object, '') = a.root_object)
    RETURNING a.root_pid, a.root_object, a.application_name, a.max_blocked_at, a.notify_count
  LOOP
    PERFORM pg_notify(lock_tree_notify_resolved.channel, json_build_object(
      -- The same three contract keys as lock_tree_notify(), and for the same reasons.
      --
      -- `subject` is built from the row being swept, and it has to come out the same as the onset
      -- payload's or a listener cannot pair this message with the alerting one, which is the entire
      -- job of the key. Same expression, deliberately, rather than a second definition of "identity".
      'tool',             'pg_lock_tree',
      'subject',          coalesce(nullif(gone.root_object, ''), 'pid ' || gone.root_pid),
      'sampled_at',       statement_timestamp(),
      'event',            'cleared',
      -- Added in 1.2.0: the last level the incident reached, which is the swept row's notify_count.
      -- `previous_level` is deliberately absent here, not present-and-null: a cleared payload has no
      -- escalation, and the contract says the key is omitted. `notified_count` below carries the
      -- same value under its older name, because keys are only ever added.
      'level',            gone.notify_count,
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

  RETURN n;
END
$fn$;
