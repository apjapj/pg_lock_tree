/* pg_lock_tree--0.2--0.3.sql
 *
 * 0.3 splits the action block in two. Nothing about the view changes: lock_tree still returns
 * the same columns with the same full, unabbreviated values, so anything selecting from it,
 * or grepping for 'AccessExclusiveLock', is unaffected.
 *
 *   lock_tree_roots()    suggested_action only, and only for the two cases that were wrong.
 *   lock_tree_actions()  same signature, different output. It now describes rather than
 *                        imitates code, and reads the lock_tree.actions setting.
 *   lock_tree_command()  new. One executable statement per root, for psql's \gexec.
 *
 * All three keep their return types, so every OR REPLACE below is signature-compatible.
 * There is no table or view to migrate.
 */

-- 0.2 gave a prepared transaction (pid 0) the generic advice "try pg_cancel_backend(0)", which
-- returns false and warns that PID 0 is not a PostgreSQL backend process. The one case where
-- the queue is genuinely stuck and the operator has no other signal got a suggestion that
-- could not work. It now names the catalog entry that can. The second case, never suggest
-- terminating the session that is asking the question, was reachable and would have
-- disconnected the operator mid-inspection.
CREATE OR REPLACE FUNCTION @extschema@.lock_tree_roots()
RETURNS TABLE (
  root_pid          int,
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
  SELECT r.pid,
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
             THEN 'Prepared transaction: it has no backend, so cancelling or terminating it '
                  || 'does nothing. Run SELECT gid FROM pg_prepared_xacts, then '
                  || 'ROLLBACK PREPARED ''<gid>''.'
           -- Never hand the operator a command that kills the session they are typing in.
           WHEN r.pid = pg_backend_pid()
             THEN 'This is your own session, so there is nothing to terminate. Re-run from '
                  || 'another connection.'
           WHEN r.state LIKE 'idle in transaction%'
             THEN format('Idle in an open transaction. SELECT pg_terminate_backend(%s);', r.pid)
           ELSE format('Try SELECT pg_cancel_backend(%s); then pg_terminate_backend(%s) if it does not clear.',
                       r.pid, r.pid)
         END
  FROM @extschema@.lock_tree r
  JOIN @extschema@.lock_tree t ON t.root_pid = r.pid
  WHERE r.depth = 0
  GROUP BY r.pid, r.state, r.usename, r.datname, r.application_name,
           r.xact_age, r.state_age, r.query
  ORDER BY count(t.pid) DESC, r.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_roots() IS
  'Head-of-line blockers, most sessions blocked first, with a suggested next step.';

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

COMMENT ON FUNCTION @extschema@.lock_tree_actions() IS
  'A written description of each root blocker and its blast radius, ordered by how many '
  'sessions each one unblocks. Every line is a SQL comment: this describes, it does not run. '
  'Use lock_tree_command() for statements you can execute. SET lock_tree.actions = off '
  'suppresses it entirely, for anyone who prefers the columns in lock_tree_roots().';

CREATE FUNCTION @extschema@.lock_tree_command()
RETURNS TABLE (command text)
LANGUAGE sql STABLE
AS $$
  SELECT format('SELECT %s(%s);',
                CASE WHEN state LIKE 'idle in transaction%'
                     THEN 'pg_terminate_backend' ELSE 'pg_cancel_backend' END,
                root_pid)
  FROM @extschema@.lock_tree_roots()
  WHERE root_pid <> 0
    AND root_pid <> pg_backend_pid()
  ORDER BY blocked_sessions DESC, root_pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_command() IS
  'One executable statement per root blocker, ordered by how many sessions each unblocks: '
  'pg_terminate_backend() for an idle-in-transaction blocker, pg_cancel_backend() for anything '
  'else. Intended for psql: SELECT command FROM lock_tree_command() \gexec. Excludes '
  'prepared transactions, which have no backend, and your own session.';
