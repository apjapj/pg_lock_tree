/* pg_lock_tree--1.4.0--1.5.0.sql
 *
 * 1.5.0 adds lock_tree_backend(pid): one backend with its type, direct blockers, wait fields and
 * granted locks. Additive; no existing object, row type or grant changes.
 */
\echo Use "ALTER EXTENSION pg_lock_tree UPDATE TO '1.5.0'" to load this file. \quit

-- One backend, named: its type, its direct blockers, what it waits for and what it holds. The tree
-- shows the whole chain; an incident payload or a paste from an alert usually has one pid and needs
-- the answer without the rest. It works for a session that is not in the tree at all, because it
-- starts from pg_stat_activity and only joins the tree for the wait fields.
--
-- holds is every granted lock the backend has, rendered "mode on object". A backend can hold many;
-- this is one pid, so that is the useful answer rather than a second aggregation to join.
CREATE FUNCTION @extschema@.lock_tree_backend(p_pid int)
RETURNS TABLE (
  pid              int,
  datname          text,
  backend_type     text,
  usename          text,
  application_name text,
  state            text,
  wait_event_type  text,
  wait_event       text,
  waiting_for      text,
  wait_age         interval,
  xact_age         interval,
  state_age        interval,
  blocked_by       int[],
  holds            text[],
  query            text
)
LANGUAGE sql STABLE
AS $$
  WITH a AS (
    SELECT s.pid, s.datname::text AS datname, s.backend_type, s.usename::text AS usename,
           s.application_name, s.state, s.wait_event_type, s.wait_event, s.query
      FROM pg_stat_activity s
     WHERE s.pid = p_pid
  ),
  t AS (
    SELECT l.pid, l.blocked_by, l.waiting_for, l.wait_age, l.xact_age, l.state_age
      FROM @extschema@.lock_tree l
     WHERE l.pid = p_pid
  ),
  held AS (
    SELECT l.pid,
           array(
             SELECT DISTINCT l2.mode || ' on ' ||
                    CASE
                      WHEN l2.relation IS NULL THEN l2.locktype
                      WHEN l2.database = (SELECT d.oid FROM pg_database d
                                           WHERE d.datname = current_database())
                        THEN l2.relation::regclass::text
                      ELSE 'relation ' || l2.relation || ' in database ' || l2.database
                    END
               FROM pg_locks l2
              WHERE l2.pid = l.pid AND l2.granted
              ORDER BY 1
           ) AS holds
      FROM pg_locks l
     WHERE l.pid = p_pid AND l.granted
     GROUP BY l.pid
  )
  SELECT a.pid, a.datname, a.backend_type, a.usename, a.application_name,
         a.state, a.wait_event_type, a.wait_event,
         t.waiting_for, t.wait_age, t.xact_age, t.state_age,
         coalesce(t.blocked_by, '{}'::int[]),
         coalesce(h.holds, '{}'::text[]),
         a.query
    FROM a
    LEFT JOIN t    ON t.pid = a.pid
    LEFT JOIN held h ON h.pid = a.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_backend(int) IS
  'One backend by pid: database, backend_type, application, wait_event, the lock it waits for and '
  'for how long, its immediate blockers, and every granted lock it holds as "mode on object". Empty '
  'when the pid has gone. Read-only; visibility is the caller''s pg_stat_activity and pg_locks '
  'privileges, so a role without pg_read_all_stats sees less, not a different answer.';
