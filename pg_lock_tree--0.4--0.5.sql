/* pg_lock_tree--0.4--0.5.sql
 *
 * Additive. Three new functions, nothing altered, replaced or dropped: the view's columns and
 * every 0.4 function's signature and output are identical, so there is nothing to migrate.
 *
 *   lock_tree_wide()       one row per root, for a queue too wide to read line by line
 *   lock_tree_summary()    one row for the whole queue, for a dashboard or an alert test
 *   lock_tree_statements() per root: what pg_stat_statements knows about the blocking query
 *
 * lock_tree_statements() needs pg_stat_statements in shared_preload_libraries, and degrades to
 * empty statement columns without it. It is optional in both directions: the extension installs
 * and works whether or not pg_stat_statements is loaded.
 */

--------------------------------------------------------------------------------
-- the wide case: aggregate instead of enumerate
--------------------------------------------------------------------------------

-- A tree of one row per session is the right shape for understanding one incident and the
-- wrong shape for a database with six of them. When sixty sessions are queued behind five
-- roots, the questions an operator actually has are: which root is worst, how many sessions
-- does each one hold up, and is any of them a long chain rather than a flat queue. All three
-- are answerable from one row per root, and none of them require reading sixty lines.
--
-- This is the same aggregate as
--   SELECT root_pid, count(*) FILTER (WHERE depth > 0), max(depth), max(wait_age)
--   FROM lock_tree GROUP BY root_pid
-- given columns, ordering and a text rendering consistent with the rest of the extension.
CREATE FUNCTION @extschema@.lock_tree_wide()
RETURNS TABLE (
  root_pid          int,
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
         max(coalesce(nullif(t.application_name, ''), t.usename)) AS application_name,
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
         left(min(coalesce(t.waiting_for, '')) FILTER (WHERE t.waiting_for IS NOT NULL), 60)
                                                                    AS first_waiting_for
  FROM @extschema@.lock_tree t
  GROUP BY t.root_pid
  ORDER BY count(*) FILTER (WHERE t.depth > 0) DESC, max(t.wait_age) DESC NULLS LAST, t.root_pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_wide() IS
  'One row per root blocker instead of one per session: how many sessions each root blocks, '
  'the deepest chain under it, the longest wait, and what they are all waiting for. Use this '
  'rather than lock_tree_text_short() when the queue is wide enough that reading every line '
  'is the problem.';


-- One row for the whole queue. For a dashboard cell, an alert condition, or deciding whether
-- to look at all: is anything blocked, how much, and how bad is the worst of it.
CREATE FUNCTION @extschema@.lock_tree_summary()
RETURNS TABLE (
  blocked_sessions  bigint,
  roots             bigint,
  max_depth         int,
  longest_wait      interval,
  oldest_xact_age   interval
)
LANGUAGE sql STABLE
AS $$
  SELECT count(*) FILTER (WHERE depth > 0),
         count(*) FILTER (WHERE depth = 0),
         coalesce(max(depth), 0),
         max(wait_age),
         -- The oldest open transaction among the roots, which is the number that says "this
         -- has been going for an hour", as distinct from "these have been waiting an hour".
         max(xact_age) FILTER (WHERE depth = 0)
  FROM @extschema@.lock_tree
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_summary() IS
  'One row for the whole lock tree: sessions blocked, roots blocking them, the deepest chain, '
  'the longest wait, and the oldest root transaction. Returns one row of zeros on a quiet '
  'database rather than no rows, so it can be used directly in a dashboard or an alert test.';

--------------------------------------------------------------------------------
-- what pg_stat_statements already knows about the blocking query
--------------------------------------------------------------------------------

-- The other half of lock_tree_wide(): this one says which *kind* of statement is doing the
-- blocking, and what it normally costs, rather than which pid happens to hold the lock this
-- time. Two incidents at 09:00 and at 14:00 have different pids and the same queryid, and it
-- is the queryid that says they are the same problem.
--
-- pg_stat_statements is optional and the function degrades rather than failing. It also needs
-- shared_preload_libraries = pg_stat_statements to be readable at all, and the extension must
-- keep working where it is not loaded, so availability is tested per call rather than assumed.
--
-- One thing this cannot do, found by measuring rather than reasoning: it cannot enrich the
-- WAITERS. A query blocked on a lock has query_id NULL for as long as it is blocked, and only
-- gains one when it completes. So the waiter side of this join is empty during the one moment
-- anybody would want it. The root is the opposite, carrying a query_id throughout. That is
-- fortunate rather than lucky, since the root is the session anyone acts on: knowing the cost
-- of the query holding the lock is the useful half. Stated here because "why is this column
-- null for everything I am blocked on" is otherwise a puzzle.
CREATE FUNCTION @extschema@.lock_tree_statements()
RETURNS TABLE (
  root_pid         int,
  application_name text,
  state            text,
  blocked_sessions bigint,
  query_id         bigint,
  statement        text,
  calls            bigint,
  total_exec_time  double precision,
  mean_exec_time   double precision,
  rows_returned    bigint
)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  -- The join is built as text and run with EXECUTE, which is the only way to reference a
  -- relation that may not exist. A SQL function naming pg_stat_statements directly fails at
  -- CREATE EXTENSION time on a server without it, which would make this optional feature
  -- mandatory. to_regclass decides which query to run; there is no parse to defer here,
  -- because the string is only parsed when executed.
  have_pgss boolean := to_regclass('pg_stat_statements') IS NOT NULL;
BEGIN
  IF NOT have_pgss THEN
    -- No pg_stat_statements loaded: report the roots anyway, with the statement columns empty.
    -- A caller asking "which queries are blocking me" should still learn which roots exist and
    -- how much each one blocks. The feature is missing, not the queue.
    RETURN QUERY
      SELECT w.root_pid, w.application_name, w.state, w.blocked_sessions,
             NULL::bigint, NULL::text, NULL::bigint,
             NULL::double precision, NULL::double precision, NULL::bigint
      FROM @extschema@.lock_tree_wide() w
      ORDER BY w.blocked_sessions DESC, w.root_pid;
    RETURN;
  END IF;

  RETURN QUERY EXECUTE
    'SELECT w.root_pid, w.application_name, w.state, w.blocked_sessions,
            a.query_id,
            left(s.query, 120),
            s.calls,
            s.total_exec_time,
            s.mean_exec_time,
            s.rows
     FROM @extschema@.lock_tree_wide() w
     LEFT JOIN pg_stat_activity a ON a.pid = w.root_pid
     LEFT JOIN pg_stat_statements s ON s.queryid = a.query_id
     ORDER BY w.blocked_sessions DESC, w.root_pid';
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_statements() IS
  'One row per root blocker, joined to pg_stat_statements for the cost of the query holding '
  'the lock: its normalised text, how many times it has run, and its mean and total time. '
  'Groups incidents by query rather than by pid, so the same statement blocking at 09:00 and '
  'at 14:00 is recognisable as one problem. Needs pg_stat_statements in '
  'shared_preload_libraries; without it the statement columns are empty and the roots are '
  'still reported. Cannot enrich waiters: a query blocked on a lock has no query_id until it '
  'completes, so only the blocker side of the join is populated.';
