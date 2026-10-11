-- pg_lock_tree 1.1.15 -> 1.1.16
--
-- The smaller half of the review behind 1.1.15, and one defect it led to. No signature, returned
-- column or table changes. CHANGELOG.md has the measurements.
--
--   lock_tree_policy_key()          NEW: the one definition of the alert policy key.
--   lock_tree_notify()              builds its key with it.
--   lock_tree_notify_resolved()     builds its key with it, and decides once: the DELETE ... RETURNING
--                                   that forgets a root is what reports it cleared. It read the live
--                                   tree twice before, so a root that came back in between was
--                                   reported cleared and kept, and then never alerted again.
--   lock_tree_wide()                first_waiting_for is what the longest waiter wants, not min().
--   lock_tree_actions()             nothing on a quiet database, not a lone header.
--   lock_tree_age(), lock_tree_mode_short(), lock_tree_state_short()   PARALLEL SAFE.
--
-- Existing functions change by CREATE OR REPLACE and ALTER FUNCTION, never DROP, so grants and
-- COMMENTs are kept, as pg_lock_tree--1.1.10--1.1.12.sql explains. The new helper is created with
-- the default privilege, EXECUTE for PUBLIC, like the other helpers: lock_tree_notify() and
-- lock_tree_notify_resolved() run with their caller's rights and call it, so a role that may call
-- them must be able to call it. Bodies are lifted verbatim from pg_lock_tree--1.1.16.sql.

ALTER FUNCTION @extschema@.lock_tree_age(interval) PARALLEL SAFE;
ALTER FUNCTION @extschema@.lock_tree_mode_short(text) PARALLEL SAFE;
ALTER FUNCTION @extschema@.lock_tree_state_short(text) PARALLEL SAFE;

CREATE FUNCTION @extschema@.lock_tree_policy_key(min_blocked integer, min_depth integer, min_wait interval)
RETURNS text
LANGUAGE sql STABLE
PARALLEL SAFE
AS $$
  SELECT format('blocked>=%s depth>=%s wait>=%s',
                coalesce(CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                              ELSE min_blocked END::text, 'off'),
                coalesce(CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                              ELSE min_depth   END::text, 'off'),
                coalesce(CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                              ELSE min_wait END::text, 'off'))
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_policy_key(integer, integer, interval) IS
  'The alert policy key lock_tree_notify() and lock_tree_notify_resolved() share: the thresholds as '
  'one string, with off for a threshold that is NULL or below its minimum.';

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_actions()
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  WITH r AS (
    SELECT root_pid, state, application_name, usename,
           blocked_sessions, max_depth, longest_wait
    FROM @extschema@.lock_tree_roots()
  ), numbered AS (
    SELECT row_number() OVER (ORDER BY blocked_sessions DESC, root_pid) AS n, r.*
    FROM r
  ), lines AS (
    -- sort 0 = header, 1..n = one description per root, 2..3 = footer, so it reads top to
    -- bottom. The column is named `body` throughout: `line` is a reserved word in SQL and
    -- cannot be used as a column alias here.
    SELECT 0 AS ord, 0 AS seq,
           format('-- %s root blocker(s). Most sessions unblocked first.', count(*)) AS body
    FROM numbered
    -- Under the same guard as the footer since 1.1.16. Before, a quiet database got this header
    -- alone, "0 root blocker(s)", while lock_tree_command() returned nothing.
    HAVING count(*) > 0
    UNION ALL
    SELECT 1, n,
           format('-- %s. %s: %s, blocks %s session(s), chain depth %s%s',
                  n,
                  coalesce(nullif(application_name, ''),
                           coalesce(nullif(usename, ''), 'pid ' || root_pid)),
                  CASE WHEN root_pid = 0
                       THEN 'prepared transaction, no backend to act on'
                       ELSE state END,
                  blocked_sessions,
                  max_depth,
                  CASE WHEN longest_wait IS NOT NULL
                       THEN format(', longest wait %s', @extschema@.lock_tree_age(longest_wait))
                       ELSE '' END)
    FROM numbered
    UNION ALL
    SELECT 2, 0,
           '-- Descriptions, not commands. Every line here is a comment. For statements you '
           || 'can run: SELECT command FROM lock_tree_command().'
    WHERE EXISTS (SELECT 1 FROM numbered)
    UNION ALL
    SELECT 3, 0,
           '-- Terminating a session rolls back its transaction. Re-run the tree afterwards.'
    WHERE EXISTS (SELECT 1 FROM numbered)
  ), filtered AS (
    -- No output row may be NULL: psql renders NULL as an empty line, which would put gaps in
    -- the middle of the block. Only the first header row survives.
    SELECT row_number() OVER (ORDER BY ord, seq) AS final,
           CASE WHEN ord = 0 AND row_number() OVER (ORDER BY ord, seq) > 1
                THEN NULL ELSE body END AS body
    FROM lines
  )
  SELECT coalesce(body, '')
  FROM filtered
  WHERE body IS NOT NULL
    AND lower(coalesce(nullif(current_setting('lock_tree.actions', true), ''), 'on'))
        NOT IN ('off', 'false', 'no', '0')
  ORDER BY final
$$;

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_wide()
RETURNS TABLE (
  root_pid          int,
  -- Beside root_pid rather than last, because the two are the root's identity and belong next to
  -- each other: root_pid alone is not enough for a prepared transaction, and a reader who has to
  -- scroll to the end of the row to learn that is the reader who draws the wrong conclusion.
  root_object       text,
  application_name  text,
  state             text,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  wait_events       text[],
  first_waiting_for text
)
LANGUAGE sql STABLE
AS $$
  -- Aggregate over lock_tree directly rather than joining lock_tree to itself: the root row is
  -- already in there at depth 0, and self-joining to find it is the join that goes wrong the
  -- first time someone edits this.
  SELECT t.root_pid,
         t.root_object,
         -- The ROOT's, as state below is. Until 1.1.15 this was max() over the whole tree, so a
         -- waiter whose application_name sorted after the root's was reported as the root's, in
         -- the NOTIFY payload that alerting.md tells a listener to key on. test/08 passed because
         -- its waiters' names happened to sort first.
         max(coalesce(nullif(t.application_name, ''), t.usename)) FILTER (WHERE t.depth = 0)
                                                                    AS application_name,
         -- Every row of a chain carries the same root, so the root's own state is what the
         -- depth-0 row says. Taking max() over all of them would report a waiter's state, so
         -- read it from the depth-0 row instead.
         max(t.state) FILTER (WHERE t.depth = 0)                  AS state,
         count(*) FILTER (WHERE t.depth > 0)                      AS blocked_sessions,
         max(t.depth)                                              AS max_depth,
         max(t.wait_age)                                           AS longest_wait,
         -- Distinct, because sixty rows of the same wait event is one fact, not sixty.
         array_agg(DISTINCT coalesce(t.wait_event, '?'))          AS wait_events,
         -- What the waiters are after, abbreviated: the mode is the same on all of them in
         -- the common case, and the point here is which lock, not which of forty sessions.
         -- What the longest-waiting session wants, which is what "first" promises. Until 1.1.16 this
         -- was min(), the alphabetically least lock description, which agreed only when every
         -- waiter in the tree wanted the same lock.
         left((array_agg(t.waiting_for ORDER BY t.wait_age DESC NULLS LAST, t.pid)
                 FILTER (WHERE t.waiting_for IS NOT NULL))[1], 60)
                                                                    AS first_waiting_for
  FROM @extschema@.lock_tree t
  -- Grouped by the pair, not the pid. Two prepared transactions are both pid 0, so grouping on
  -- pid alone merged them and reported one root whose blocked_sessions was the sum of two
  -- blockers each holding half as much. That is the number an operator acts on.
  GROUP BY t.root_pid, t.root_object
  ORDER BY count(*) FILTER (WHERE t.depth > 0) DESC, max(t.wait_age) DESC NULLS LAST,
           t.root_pid, t.root_object
$$;

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
