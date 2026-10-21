-- pg_lock_tree 1.3.0 -> 1.4.0
--
-- Adds lock_tree_deadlock_cycle(): names each participant in a live wait-for cycle, with blocked_by
-- naming the immediate blocker. Additive; no existing object changes.

\echo Use "ALTER EXTENSION pg_lock_tree UPDATE TO '1.4.0'" to load this file. \quit

CREATE FUNCTION @extschema@.lock_tree_deadlock_cycle()
RETURNS TABLE (
  pid              int,
  state            text,
  usename          text,
  application_name text,
  waiting_for      text,
  blocked_by       int[],
  query            text
)
LANGUAGE sql STABLE
AS $$
  SELECT t.pid, t.state, t.usename, t.application_name, t.waiting_for, t.blocked_by, t.query
    FROM @extschema@.lock_tree t
   WHERE t.depth = 0
     AND cardinality(t.blocked_by) > 0
   ORDER BY t.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_deadlock_cycle() IS
  'The live wait-for cycle: one row per participant, with blocked_by naming the immediate blocker. Empty '
  'once PostgreSQL has resolved the cycle; the server log is the after-the-fact record.';

-- 1.3.0 already sets this on lock_tree_sample(); repeated here so a 1.4.0 upgrade made from an
-- earlier 1.3.0 build still gets it. SET on an existing function is idempotent.
ALTER FUNCTION @extschema@.lock_tree_sample() SET lock_timeout = '1s';
