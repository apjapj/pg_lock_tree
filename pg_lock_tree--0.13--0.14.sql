/* pg_lock_tree--0.13--0.14.sql
 *
 * Let the history be looked at, not only queried.
 *
 *   lock_tree_replay_samples (view)   one row per sample: when, how wide, how deep, who was at the head
 *   lock_tree_replay(at timestamptz)  the tree as it was at the nearest past sample
 *   lock_tree_replay_text(at, width)  the same, indented, in the live renderer's layout
 *
 * Everything already in the extension answers questions about the present, or about totals over a
 * window. None of them can show the SHAPE of an incident that has ended: sixty sessions behind one
 * idle-in-transaction root at depth three, or five independent roots at once. That shape lived only
 * in lock_tree_history as one row per session per sample, with nothing to render it.
 *
 * NINE COLUMNS OF lock_tree ARE NOT HERE, and that is the honest part rather than an oversight:
 *
 *   path, blocked_by   not reconstructible. The history stores one row per session, not the edge
 *                      between them, so there is no way to know which depth-1 session a depth-2
 *                      session was actually behind. Anything derived from path goes with it.
 *   usename, datname, client_addr, wait_event_type, wait_event, xact_age, state_age
 *                      simply were not recorded. Adding them now would widen the history for every
 *                      future sample on every database, and would not retroactively supply the past.
 *
 * `at` is a target rather than an exact key, and the sample chosen is reported in the sampled_at
 * column of every row, so what you actually got is visible rather than assumed. NULL means the most
 * recent sample.
 *
 * Nothing existing is changed. The view is new, both functions are new, and no table is touched, so
 * this update is instant on a history of any size.
 */

CREATE VIEW @extschema@.lock_tree_replay_samples AS
SELECT h.sampled_at,
       count(*) FILTER (WHERE h.depth = 0) AS roots,
       count(*) FILTER (WHERE h.depth > 0) AS sessions_blocked,
       max(h.depth)                       AS max_depth,
       max(h.wait_age)                    AS longest_wait,
       -- FILTER rather than a WHERE on a second aggregate, so one pass over the table gives every
       -- column. array_agg on root rows only: a waiter's application is not who was blocking.
       array_agg(DISTINCT h.application_name ORDER BY h.application_name)
         FILTER (WHERE h.depth = 0)      AS applications,
       -- Which statement was at the head, where it was recorded. query_id is on root rows only.
       array_agg(DISTINCT h.query_id ORDER BY h.query_id)
         FILTER (WHERE h.depth = 0 AND h.query_id IS NOT NULL) AS query_ids
FROM @extschema@.lock_tree_history h
GROUP BY h.sampled_at;

COMMENT ON VIEW @extschema@.lock_tree_replay_samples IS
  'One row per sample in lock_tree_history: when it was taken, how many roots were blocking, how '
  'many sessions were behind them, how deep the worst chain went, the longest single wait, and the '
  'applications and query ids at the head. This is how you find out which samples exist, since '
  'the history itself holds one row per session rather than one per sample. Order by sampled_at '
  'DESC to start from the most recent.';


--------------------------------------------------------------------------------
-- the tree as it was
--------------------------------------------------------------------------------

-- The live view reads pg_stat_activity. This reads the history, so it can answer for a moment that
-- has passed.
--
-- `at` is a TARGET, not an exact key. The sample nearest it is used, and which one that was is the
-- first column of every row, so you always see what you actually got rather than having to trust
-- that you got what you asked for. Ties go to the earlier sample, which is arbitrary but at least
-- consistent.
--
-- The column list is what the history recorded, in the live view's order where they overlap. Nine
-- columns of lock_tree are absent and cannot be supplied:
--
--   path              not reconstructible. The history has one row per session per sample, not the
--                     edge between them, so there is no way to know which depth-1 session a depth-2
--                     session was actually behind. Anything derived from it, blocked_by included,
--                     goes with it.
--   usename, datname, client_addr, wait_event_type, wait_event, xact_age, state_age
--                     simply were not recorded. Adding them means a wider history for every future
--                     sample on every database, for figures nobody has asked for yet.
--
-- ONE COLUMN READS BACK DIFFERENTLY FROM THE LIVE VIEW, and that is a good thing.
--
-- lock_tree_sample() is SECURITY DEFINER SET search_path = pg_catalog. Inside it regclass cannot
-- resolve a relation in public, so the relation name renders QUALIFIED. The live lock_tree is read
-- with the caller's search_path, so the same lock renders unqualified there:
--
--   lock_tree.waiting_for          AccessShareLock on ledger
--   lock_tree_history.waiting_for   AccessShareLock on public.ledger
--
-- Measured, not inferred. The live view's rendering is the path-dependent one this extension
-- already documents as cosmetic, because nothing keys on it. The history's is stable: the same lock
-- renders the same way in every row forever, whatever the reader's search_path was. A replay that
-- said "ledger" in one sample and "public.ledger" in the next would be worse.
--
-- A gap in the column list is a gap in the data, not a formatting choice, and this function says so
-- rather than padding with NULLs that would be indistinguishable from a session which genuinely had
-- no client address.
CREATE FUNCTION @extschema@.lock_tree_replay(as_of timestamptz DEFAULT NULL)
RETURNS TABLE (
  sampled_at       timestamptz,
  root_pid         int,
  root_object      text,
  depth            int,
  pid              int,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text,
  query_id         bigint
)
LANGUAGE sql STABLE
AS $$
  -- The parameter is named as_of and not at because PostgreSQL resolves a bare `at` against the
  -- function's own RETURNS TABLE row type rather than against the argument, and the failure is
  -- "missing FROM-clause entry for table lock_tree_replay". A parameter whose name is not one of the
  -- output columns has no such shadowing.
  --
  -- The distance is computed in its own CTE so the ordering can use it, because PostgreSQL refuses
  -- to let a SELECT DISTINCT order by an expression that is not in its select list. DISTINCT is
  -- unnecessary anyway: ordering by (distance, instant) and taking one row returns a single instant
  -- however many sessions happened to be in it.
  --
  -- coalesce(as_of, clock_timestamp()) is what makes NULL mean "the most recent sample": with no
  -- target, the nearest sample to now is the latest one at or before it.
  WITH scored AS (
    SELECT h.sampled_at,
           abs(extract(epoch FROM (h.sampled_at - coalesce(as_of, clock_timestamp())))) AS distance
    FROM @extschema@.lock_tree_history h
  ),
  target AS (
    SELECT sampled_at
    FROM scored
    ORDER BY distance, sampled_at
    LIMIT 1
  )
  SELECT h.sampled_at,
         h.root_pid,
         h.root_object,
         h.depth,
         h.pid,
         h.state,
         h.waiting_for,
         h.wait_age,
         h.application_name,
         h.query,
         h.query_id
  FROM @extschema@.lock_tree_history h
  JOIN target t USING (sampled_at)
  -- Same ordering as the live view, minus path. depth then pid stands in for the path order, which
  -- is the same ordering whenever the tree is well formed and is stable when it is not.
  ORDER BY h.root_pid, h.root_object NULLS FIRST, h.depth, h.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_replay(timestamptz) IS
  'The lock tree as it was at a past sample, reconstructed from lock_tree_history. Takes a target '
  'timestamp and uses the sample NEAREST to it, reporting which one in the sampled_at column of every '
  'row; NULL means the most recent. Returns the columns the history recorded: sampled_at, root_pid, '
  'root_object, depth, pid, state, waiting_for, wait_age, application_name, query and query_id. '
  'Nine columns of lock_tree are absent and cannot be supplied, path and blocked_by because the '
  'history stores one row per session rather than the edge between them, and usename, datname, '
  'client_addr, wait_event_type, wait_event, xact_age and state_age because they were never '
  'recorded. waiting_for reads back SCHEMA-QUALIFIED where the live view does not, because '
  'lock_tree_sample() runs with search_path = pg_catalog and regclass cannot resolve unqualified '
  'there. That is deliberate: the live rendering is the path-dependent one, and the history''s is '
  'stable across every sample. See lock_tree_replay_samples for what samples exist.';


--------------------------------------------------------------------------------
-- the same, as something to read
--------------------------------------------------------------------------------

-- Prose during an incident is what lock_tree_text() is for. This is the 3am version of it: the
-- incident is over, you are reading about it, and you want the shape rather than a query.
--
-- Same layout as the live renderer, with the columns the history has. The root line carries its
-- application and query, and each waiter line carries how long it had been waiting, what it wanted,
-- and its own query. The live version also prints xact_age on the root, which is often the most
-- telling number in the whole tree, and replay cannot because it was not recorded.
CREATE FUNCTION @extschema@.lock_tree_replay_text(as_of timestamptz DEFAULT NULL, query_width int DEFAULT 60)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN r.depth = 0
           THEN format('%s%s  %s  %s  %s',
                       r.pid,
                       CASE WHEN r.root_object IS NULL THEN ''
                            ELSE format(' (%s)', r.root_object) END,
                       r.state,
                       -- '(none set)' rather than an empty column, because an unlabelled blocker is a
                       -- finding and a blank between two spaces does not look like one.
                       coalesce(nullif(r.application_name, ''), '(none set)'),
                       left(regexp_replace(coalesce(r.query, ''), '\s+', ' ', 'g'), query_width))
           ELSE format('%s%s  %s  %s  %s',
                       repeat('  ', r.depth - 1) || '└─',
                       r.pid,
                       @extschema@.lock_tree_age(r.wait_age),
                       'for ' || coalesce(r.waiting_for, '(not recorded)'),
                       left(regexp_replace(coalesce(r.query, ''), '\s+', ' ', 'g'), query_width))
         END
  FROM @extschema@.lock_tree_replay(as_of) r
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_replay_text(timestamptz, int) IS
  'lock_tree_replay() rendered as indented text, in the same layout as lock_tree_text(): a root line '
  'with its application and query, then each waiter indented by depth with its wait, what it wanted '
  'and its query. Takes the same target timestamp as lock_tree_replay(), so NULL means the most '
  'recent sample. The live renderer also prints the root''s xact_age, which is often the most telling '
  'number in the tree; replay cannot, because xact_age was not recorded.';
