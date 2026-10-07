-- pg_lock_tree 1.1.3 -> 1.1.4
--
-- One addition, no change to anything that exists: lock_tree_deadlock_participants().
--
-- It is a new function, so this script declares it with CREATE rather than CREATE OR REPLACE. That
-- is deliberate and is the opposite of the 1.1.3 -> 1.1.4 draft that was discarded: a body lifted
-- verbatim from the release file needs CREATE OR REPLACE to replace an existing function, and a
-- genuinely new object must not carry it, because OR REPLACE on a name that does not exist yet is
-- legal but hides the fact that you have added something rather than changed something.
--
-- The empty-script rule still applies to releases that change nothing, and the reason is unchanged:
-- an extension with no update script for a released version cannot be upgraded with ALTER EXTENSION
-- ... UPDATE, and DROP then CREATE destroys lock_tree_history. This release is not empty.
--
-- Why a function and not a column on lock_tree_history, which was the open design question in
-- docs/roadmap.md. A deadlock participant is only in the history for samples taken inside the
-- deadlock_timeout window, so a column would be NULL in nearly every row of the table that matters.
-- An empty column on the hot table is worse than no column: a reader who queries it sees NULL and
-- concludes no deadlock happened, which is the specific misreading the roadmap warned about. A read
-- function costs no storage, changes no schema, and carries the caveat in a COMMENT that a reader
-- meets where they use it.
--
-- The deadlocks() counter is untouched and remains the way to find the deadlocks this misses: it
-- moves whether or not anyone was looking.

CREATE FUNCTION @extschema@.lock_tree_deadlock_participants(
  since interval DEFAULT interval '7 days')
RETURNS TABLE (
  sampled_at       timestamptz,
  pid              integer,
  root_pid         integer,
  state            text,
  application_name text,
  wait_age         interval,
  waiting_for      text,
  query            text,
  partner_pids     integer[]
)
LANGUAGE sql STABLE
AS $$
  SELECT h.sampled_at,
         h.pid,
         h.root_pid,
         h.state,
         h.application_name,
         h.wait_age,
         h.waiting_for,
         h.query,
         (SELECT array_agg(p.pid ORDER BY p.pid)
            FROM @extschema@.lock_tree_history p
           WHERE p.sampled_at = h.sampled_at
             AND p.depth = 0
             AND p.waiting_for IS NOT NULL
             AND p.pid <> h.pid)
  FROM @extschema@.lock_tree_history h
  WHERE h.depth = 0
    AND h.waiting_for IS NOT NULL
    AND h.sampled_at >= statement_timestamp() - since
  ORDER BY h.sampled_at, h.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_deadlock_participants(interval) IS
  'Both participants of any deadlock the history happened to catch, one row per participant per '
  'sample, with partner_pids naming the other side. Empty is the normal case and does NOT mean no '
  'deadlock happened: this only has rows for samples taken while the cycle still existed, which is '
  'the deadlock_timeout before the server breaks it. With the default 1s deadlock_timeout and a 10 '
  'second sample interval, roughly one deadlock in ten is caught. lock_tree_deadlocks() is the '
  'counter that moves whether or not anyone was looking, and is how you find the ones this misses. '
  'Do not raise deadlock_timeout to catch more: it is also how long every real lock wait goes '
  'unexamined. The server log names both statements in every case; this is second-hand from the '
  'tree, so it can be wrong in the case that matters.';
