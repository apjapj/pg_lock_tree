/* pg_lock_tree--0.5--0.6.sql
 *
 * Additive. A table and three functions, nothing altered, replaced or dropped: the view's
 * columns and every 0.5 function's signature and output are identical, so there is nothing to
 * migrate.
 *
 *   lock_tree_alert()          what has been alerted on, so an incident notifies once
 *   lock_tree_notify()         raise a NOTIFY when a chain is bad enough to be worth waking for
 *   lock_tree_prune_alerts()   forget alert state orphaned by a restart or a retired channel
 *   lock_tree_sampling_advice() a defensible interval for the sample cron entry
 *
 * None of it runs by itself and none of it pages anything. lock_tree_notify() raises NOTIFY on a
 * PostgreSQL channel; connecting that channel to a pager is the deployment's job, and the payload
 * is JSON so that whatever it is can parse it.
 */

--------------------------------------------------------------------------------
-- alerting: turning "something is wrong" into "someone was told"
--------------------------------------------------------------------------------

-- Everything so far reports to whoever is already looking. History reports to whoever looks
-- later. Neither tells anyone that something is happening now, which is the moment alerting
-- exists for.
--
-- The design problem is not raising a notification, it is raising the RIGHT number of them. A
-- job that notifies on every sample turns a two-minute incident into twelve notifications and
-- trains everyone to ignore the channel, which is worse than having none: the one alert that
-- mattered gets filtered along with the noise. So lock_tree_notify() notifies on onset and on
-- escalation, and stays quiet while a chain sits at the same severity. lock_tree_alert is what
-- makes that possible.
--
-- NOTIFY rather than anything heavier, deliberately. It needs no extra process, no table to
-- drain, and no polling: any client can LISTEN, and it is transactional, so a rolled-back
-- sample never notifies. The payload is JSON on one channel prefixed with the channel name, so a
-- listener can serve several kinds of alert from one subscription and route on the payload.

-- What has already been alerted on, per channel and per root. Small by construction: one row per
-- root that is currently notable, and rows are removed as soon as the root is gone, so the table
-- holds the size of the current queue rather than its history.
--
-- max_blocked_at and max_depth_at are the high-water marks, not the latest values. That is what
-- makes an escalation distinguishable from a recovery: a root that drops from 40 sessions to 12
-- is getting better and must not re-notify, while one that goes from 12 to 40 is getting worse
-- and must.
CREATE TABLE @extschema@.lock_tree_alert (
  channel          text        NOT NULL,
  policy           text        NOT NULL,
  root_pid         int         NOT NULL,
  application_name text,
  first_seen       timestamptz NOT NULL,
  last_notified    timestamptz,
  notify_count     int         NOT NULL DEFAULT 0,
  max_blocked_at   bigint      NOT NULL DEFAULT 0,
  max_depth_at     int         NOT NULL DEFAULT 0,
  PRIMARY KEY (channel, policy, root_pid)
);

CREATE INDEX lock_tree_alert_last_notified_idx
  ON @extschema@.lock_tree_alert (last_notified);

COMMENT ON TABLE @extschema@.lock_tree_alert IS
  'What lock_tree_notify() has already alerted on, per channel, per threshold set, per root. '
  'Rows are removed when the root leaves the tree, so a chain that returns alerts again. The '
  'policy column holds the thresholds the row was written under: two different alerting policies '
  'sharing a channel would otherwise clear each other''s state, and each would re-alert on '
  'every alternate sample. Not history: lock_tree_history is that. Prune with '
  'lock_tree_prune_alerts().';



-- Notify when a root is notable, and only then. Returns how many notifications were raised,
-- which is the number worth watching: zero on every ordinary sample, one per onset or
-- escalation, and it stays at zero for as long as an incident sits at the same severity.
--
-- Thresholds, and how they combine:
--
--   A root is notable if it meets AT LEAST ONE of the criteria that are set. NULL, or 0 for
--   min_blocked, switches a criterion off. With all three set, a chain alerts if it blocks at
--   least min_blocked sessions, OR is min_deep, OR has anyone waiting min_wait. That is the
--   useful shape: a queue can be bad in ways unrelated to each other, and an operator paging on
--   "deep OR slow" rather than "deep AND slow" will not miss the incident that was both.
--
--   At least one criterion must be set. All three off means "alert on every root", which is not
--   what anyone wants from an alerting function, so it is rejected rather than quietly given a
--   default.
--
-- What this deliberately does not do:
--   - page anything. It raises a NOTIFY on a PostgreSQL channel. Wiring that to a pager is the
--     deployment's business, and the payload is JSON so that whatever it is can parse it.
--   - choose your thresholds. They are arguments. No default is right for everyone, and a
--     default nobody reads is a default nobody trusts.
--   - keep state indefinitely. Rows go when a root does, which is the normal case.
--
-- A row-at-a-time loop rather than nested upserts with a RETURNING clause. The row count is one
-- per root blocker, which is a handful, and the logic here is control flow: compare, decide,
-- write, notify. Written as a loop it reads in the order it happens, and it was the first version
-- that was correct. The alternative spelled the same decision in three nested CTEs and referred
-- to a column that did not exist.
CREATE FUNCTION @extschema@.lock_tree_notify(
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
    SELECT w.root_pid, w.application_name, w.blocked_sessions, w.max_depth, w.longest_wait,
           w.first_waiting_for,
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
       AND a.root_pid = r.root_pid;

    IF NOT FOUND THEN
      -- First time this root has been notable on this channel. That is the onset, and the one
      -- case that is always worth telling someone about.
      INSERT INTO @extschema@.lock_tree_alert
        (channel, policy, root_pid, application_name, first_seen, last_notified,
         notify_count, max_blocked_at, max_depth_at)
      VALUES (lock_tree_notify.channel, pol, r.root_pid, r.application_name,
              statement_timestamp(), statement_timestamp(), 1,
              r.blocked_sessions, r.max_depth);
      fired := fired + 1;
      root_fired := true;
    ELSIF r.blocked_sessions > prior.max_blocked_at
       OR r.max_depth > prior.max_depth_at THEN
      -- Escalation. Compared against the high-water marks rather than the previous sample, so a
      -- chain that wobbles between 40 and 12 sessions notifies once, not twice a minute.
      UPDATE @extschema@.lock_tree_alert a
         SET last_notified  = statement_timestamp(),
             notify_count   = notify_count + 1,
             max_blocked_at = greatest(max_blocked_at, r.blocked_sessions),
             max_depth_at   = greatest(max_depth_at, r.max_depth),
             application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid;
      fired := fired + 1;
      root_fired := true;
    ELSE
      -- Notable but unchanged. Stay quiet: this is the case that turns an alerting function into
      -- noise, and the whole reason lock_tree_alert exists.
      UPDATE @extschema@.lock_tree_alert a
         SET application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid;
    END IF;

    IF root_fired THEN
      PERFORM pg_notify(lock_tree_notify.channel, json_build_object(
        'channel',           lock_tree_notify.channel,
        'root_pid',          r.root_pid,
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
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t WHERE t.root_pid = a.root_pid);

  RETURN fired;
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_notify(text, integer, integer, interval) IS
  'Raise a NOTIFY on a channel when a root blocker is notable, and remember it so the same '
  'incident notifies once rather than on every sample. A root is notable if it meets AT LEAST '
  'ONE of min_blocked, min_depth or min_wait; NULL or 0 switches one off, and at least one '
  'must be set. Returns how many notifications were raised, so zero is the normal result and '
  'the one worth watching. Payloads are JSON. Wire the channel to a pager yourself: this raises '
  'NOTIFY and nothing more.';


-- Forget alert state that no longer refers to a live session.
--
-- lock_tree_notify() deletes a root's row as soon as that root stops being notable, which is
-- the normal case and needs no help. This is for the abnormal ones: a server that was rebooted
-- mid-incident keeps rows for pids that no longer exist, and a channel name that has been
-- retired keeps rows under it. Small either way, since the table is the size of the current
-- queue, so calling this from the same cron entry as the sample is enough.
CREATE FUNCTION @extschema@.lock_tree_prune_alerts(older_than interval DEFAULT interval '1 day')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH gone AS (
    DELETE FROM @extschema@.lock_tree_alert
    WHERE last_notified IS NOT NULL
      AND last_notified < clock_timestamp() - older_than
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
CREATE FUNCTION @extschema@.lock_tree_sampling_advice()
RETURNS TABLE (
  blocked_sessions bigint,
  roots            bigint,
  suggested_every  interval,
  reason           text
)
LANGUAGE sql STABLE
AS $$
  SELECT s.blocked_sessions,
         s.roots,
         -- Three bands, chosen on cost rather than taste. Under 10 sessions a sample is cheap
         -- and detail is worth having. Under 100 it is 10 times the storage and a 10 second
         -- interval still catches everything that lasts longer than a query. Past that the
         -- table is the dominant cost and 30 seconds is enough to characterise an incident.
         CASE WHEN s.blocked_sessions < 10  THEN interval '5 seconds'
              WHEN s.blocked_sessions < 100 THEN interval '10 seconds'
              ELSE interval '30 seconds' END,
         CASE WHEN s.blocked_sessions = 0
              THEN 'nothing is blocked: the table stays empty at any interval, so sample rarely'
              WHEN s.blocked_sessions < 10
              THEN 'few sessions blocked: cheap to sample finely, so keep the detail'
              WHEN s.blocked_sessions < 100
              THEN 'a busy queue: 10 seconds catches anything that lasts, at a tenth the storage'
              ELSE 'a wide queue: each sample writes a row per blocked session, so widen the interval'
         END
  FROM @extschema@.lock_tree_summary() s
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sampling_advice() IS
  'A suggested interval for lock_tree_sample(), given how many sessions are blocked right now, '
  'and why. The cost of a sample is one row per blocked session, so a wide queue argues for a '
  'wider interval. Empty when nothing is blocked, since then any interval writes nothing.';
