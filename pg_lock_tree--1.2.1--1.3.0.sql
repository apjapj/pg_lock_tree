-- pg_lock_tree 1.2.1 -> 1.3.0
--
-- Adds lock_tree_root_holds(): the hold side of the tree, one row per root-held lock that at least
-- one waiter in its tree is waiting for, with both modes and the number of waiters. New function
-- only; no existing object, column or grant changes.

\echo Use "ALTER EXTENSION pg_lock_tree UPDATE TO '1.3.0'" to load this file. \quit

CREATE FUNCTION @extschema@.lock_tree_root_holds()
RETURNS TABLE (
  root_pid         int,
  root_object      text,
  locktype         text,
  object           text,
  held_mode        text,
  waiting_mode     text,
  waiting_sessions bigint
)
LANGUAGE sql STABLE
AS $$
  WITH roots AS (
    SELECT DISTINCT root_pid, root_object FROM @extschema@.lock_tree WHERE depth = 0
  ),
  waiters AS (
    SELECT t.root_pid, t.root_object, t.pid,
           l.locktype, l.database, l.relation, l.page, l.tuple,
           l.classid, l.objid, l.objsubid, l.virtualxid, l.transactionid, l.mode
      FROM @extschema@.lock_tree t
      JOIN pg_locks l ON l.pid = t.pid AND NOT l.granted
     WHERE t.depth > 0
  ),
  held AS (
    SELECT r.root_pid, r.root_object,
           l.locktype, l.database, l.relation, l.page, l.tuple,
           l.classid, l.objid, l.objsubid, l.virtualxid, l.transactionid, l.mode
      FROM roots r
      JOIN pg_locks l
        ON (r.root_pid <> 0 AND l.pid = r.root_pid)
        OR (r.root_pid = 0 AND l.pid IS NULL)
     WHERE l.granted
  )
  SELECT h.root_pid,
         h.root_object,
         h.locktype,
         CASE
           WHEN h.relation IS NULL THEN h.locktype
           WHEN h.database = (SELECT oid FROM pg_database WHERE datname = current_database())
             THEN h.relation::regclass::text
           ELSE 'relation ' || h.relation || ' in database ' || h.database
         END,
         h.mode,
         w.mode,
         count(DISTINCT w.pid)
    FROM held h
    JOIN waiters w
      ON h.locktype = w.locktype
     AND h.database IS NOT DISTINCT FROM w.database
     AND h.relation IS NOT DISTINCT FROM w.relation
     AND h.page IS NOT DISTINCT FROM w.page
     AND h.tuple IS NOT DISTINCT FROM w.tuple
     AND h.classid IS NOT DISTINCT FROM w.classid
     AND h.objid IS NOT DISTINCT FROM w.objid
     AND h.objsubid IS NOT DISTINCT FROM w.objsubid
     AND h.virtualxid IS NOT DISTINCT FROM w.virtualxid
     AND h.transactionid IS NOT DISTINCT FROM w.transactionid
   GROUP BY h.root_pid, h.root_object, h.locktype, h.relation, h.database, h.mode, w.mode
   ORDER BY count(DISTINCT w.pid) DESC, h.root_pid, h.root_object, 4, h.mode, w.mode
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_root_holds() IS
  'The granted locks a root holds that at least one session in its tree is waiting for, with the '
  'held mode, the requested mode and the number of waiting sessions. The hold side of lock_tree.';
