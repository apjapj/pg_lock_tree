-- pg_lock_tree 1.2.0 -> 1.2.1
--
-- lock_tree_roots() now reads the lock_tree view ONCE, through a MATERIALIZED CTE, instead of
-- referencing it twice. PostgreSQL inlined both references, so the view's whole CTE chain was
-- planned and executed twice per call. Measured on PostgreSQL 18.6, idle: planning 5 to 8 ms warm
-- (18 to 26 ms in a cold backend) and execution about 2.6 ms before; about 4 ms planning and 1.5 ms
-- execution after. The median call went from about 8 ms to about 6 ms warm, against a 1 ms
-- pg_blocking_pids() floor (scripts/bench-overhead.sh).
--
-- It also closes a consistency hole. The view reads pg_stat_activity and pg_locks through volatile
-- functions; two independent evaluations could disagree between the two sides of the self-join, so
-- a root could be counted against a waiter from a different snapshot. One materialized read is one
-- snapshot.
--
-- Output is unchanged: same columns, same rows, same suggested_action text. The function changes by
-- CREATE OR REPLACE, never DROP, so grants and the COMMENT survive. The body is lifted verbatim
-- from pg_lock_tree--1.2.1.sql.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_roots()
RETURNS TABLE (
  root_pid          int,
  -- Beside root_pid, which is the only place it can go: the two are one identity, and a session
  -- root has this NULL while a prepared-transaction root has the lock it is holding.
  root_object       text,
  state             text,
  usename           text,
  datname           text,
  application_name  text,
  xact_age          interval,
  state_age         interval,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  query             text,
  suggested_action  text
)
LANGUAGE sql STABLE
AS $$
  -- The tree is read ONCE, through a MATERIALIZED CTE. This function joins the tree to itself, and
  -- two direct references to lock_tree made PostgreSQL plan and run the view's whole CTE chain
  -- twice: planning alone was 5 to 8 ms warm (18 to 26 ms cold) and execution doubled. Reading it
  -- once halves that, and it also removes a consistency hole: the view reads pg_stat_activity and
  -- pg_locks through volatile functions, so two independent evaluations can disagree mid-query and
  -- join a row against a later snapshot of itself.
  WITH tree AS MATERIALIZED (
    SELECT * FROM @extschema@.lock_tree
  )
  SELECT r.pid,
         r.root_object,
         r.state,
         r.usename,
         r.datname,
         r.application_name,
         r.xact_age,
         r.state_age,
         count(t.pid) FILTER (WHERE t.depth > 0),
         max(t.depth),
         max(t.wait_age),
         r.query,
         CASE
           -- pid 0 is a prepared transaction. It has no backend, so cancel and terminate are
           -- both no-ops on it: pg_cancel_backend(0) returns false and warns that PID 0 is
           -- not a PostgreSQL backend process. The only thing that clears it is ROLLBACK
           -- PREPARED, and the gid is not reachable from here, so name the catalog instead.
           WHEN r.pid = 0
             THEN 'Prepared transaction holding '
                  || coalesce(r.root_object, 'an unidentified object')
                  || ': it has no backend, so cancelling or terminating it does nothing. Run '
                  || 'SELECT gid FROM pg_prepared_xacts, then ROLLBACK PREPARED ''<gid''.'
           -- Never hand the operator a command that kills the session they are typing in.
           WHEN r.pid = pg_backend_pid()
             THEN 'This is your own session, so there is nothing to terminate. Re-run from '
                  || 'another connection.'
           WHEN r.state LIKE 'idle in transaction%'
             THEN format('Idle in an open transaction. SELECT pg_terminate_backend(%s);', r.pid)
           ELSE format('Try SELECT pg_cancel_backend(%s); then pg_terminate_backend(%s) if it does not clear.',
                       r.pid, r.pid)
         END
  -- Both sides of the join carry root_object, because it is part of the root's identity. Joining
  -- on pid alone put every prepared root against every prepared waiter, so two of them summed
  -- into one row claiming the combined wait count.
  FROM tree r
  JOIN tree t
    ON t.root_pid = r.pid AND t.root_object IS NOT DISTINCT FROM r.root_object
  WHERE r.depth = 0
  GROUP BY r.pid, r.state, r.usename, r.datname, r.application_name,
           r.xact_age, r.state_age, r.query, r.root_object
  ORDER BY count(t.pid) DESC, r.pid, r.root_object
$$;
