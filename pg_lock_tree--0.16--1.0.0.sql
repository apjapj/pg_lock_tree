/* pg_lock_tree--0.16--1.0.0.sql
 *
 * Stops the history from holding credentials, and fixes four upgrade-convergence defects.
 *
 * lock_tree_redact(q)                      new
 * lock_tree_sample()                       stores redacted query text
 * lock_tree_summary()                      restored; see CONVERGENCE below
 * COMMENT ON TABLE lock_tree_history
 * COMMENT ON COLUMN lock_tree_history.query_id
 * COMMENT ON FUNCTION lock_tree_notify_resolved(...)
 *
 * THE REDACTION, WHICH IS THE POINT OF THE RELEASE
 *
 * lock_tree_history kept the first 300 characters of every blocked session's query. A blocked
 * `ALTER ROLE app PASSWORD '...'` is a blocked query, and it sat in that table in full until it aged
 * out, readable by anyone with SELECT on the history and copied into every backup of the database.
 *
 * lock_tree_sample() now strips password literals in all three quoting styles, SCRAM-SHA-256
 * verifiers and md5 hashes, and does so BEFORE the 300 character truncation so that a password
 * beginning before the cut is still caught.
 *
 * The default is to redact. lock_tree.history_query = 'full' stores the query verbatim, 'none'
 * stores NULL, and any value the function does not recognise redacts, so a misspelling fails in the
 * safe direction.
 *
 * The cost is real and worth stating: two statements differing only in a password now group as one
 * row in lock_tree_incidents() and lock_tree_history_statements(). That is usually the better
 * answer, since the password is not what distinguishes the incident.
 *
 * CONVERGENCE, AND WHY THESE FOUR ARE HERE
 *
 * scripts/check-upgrade.sh compares every upgrade path against a fresh install. It found four
 * differences, and three of them were the FRESH install being wrong rather than the upgraded one:
 *
 *   lock_tree_history.query_id had no COMMENT ON COLUMN in the release file, though the 0.7 update
 *     script set one. Every fresh install therefore had an uncommented column and every upgraded
 *     database had a commented one. Fixed in the release file and here, so both paths agree.
 *
 *   COMMENT ON TABLE lock_tree_history was a version behind on every path that predated 0.12, and
 *     the sentence about query_id had been added to the release file but never re-set by an update.
 *
 *   lock_tree_summary() had lost three lines of explanatory comment, added in 0.8, on paths that did
 *     not go through 0.12. Replaced here from the release file.
 *
 *   COMMENT ON FUNCTION lock_tree_notify_resolved() said "give both the same arguments" where the
 *     release file says "use the same arguments". The release file is the correct one, and the
 *     update script that introduced the function carried the other wording.
 *
 * The remaining known difference is COLUMN POSITION on lock_tree_alert.root_object and
 * lock_tree_history.query_id, and it is permanent: ALTER TABLE ADD COLUMN appends, and rebuilding
 * lock_tree_history to reorder it would need twice the disk and an ACCESS EXCLUSIVE lock for the
 * length of the copy. check-upgrade.sh carries it as a named, checked exception rather than
 * pretending it is not there.
 *
 * No table is dropped, no column is dropped, no signature changes, so no grants are revoked.
 */

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_redact(q text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $redact$
  SELECT nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          q,
          -- The literal after PASSWORD, on one line, or a dollar-quoted string.
          --
          -- One line rather than a properly parsed string literal, and the reason is worth
          -- recording. The first version tried to parse an E-string: E?'[^']*(?:''[^']*)*'. On
          -- E'a\'b' it matched E'a\' and left a bare b' behind, because inside an E-string the
          -- escaped quote \' is indistinguishable from a terminator to a regular expression that
          -- has no idea it is looking at an E-string. Getting that right needs a real scanner, not
          -- a pattern, and a scanner is not what a redaction filter should be.
          --
          -- So this matches to the LAST quote on the line instead. That over-redacts the rare
          -- `PASSWORD 'p', VALID UNTIL '2026-01-01'`, replacing more than it needed to. Over-redacting
          -- one clause is a cosmetic loss; under-redacting is the thing this function exists to stop,
          -- and this way cannot do it.
          --
          -- [\s\S] in the dollar-quoted branch rather than . so a dollar-quoted password containing a
          -- newline is still matched: . does not cross a newline in POSIX regex.
          '(PASSWORD\s+)(E?''[^\n]*''|\$[A-Za-z_][A-Za-z0-9_]*\$[\s\S]*?\$[A-Za-z_][A-Za-z0-9_]*\$)',
          '\1''<redacted>''',
          'gi'),
        -- A SCRAM verifier: the stored form, which appears in ALTER ROLE ... PASSWORD
        -- 'SCRAM-SHA-256$...' and in arguments to a password reset function. Anchored on the
        -- algorithm name so ordinary text is not touched.
        -- Base64 alphabet only, so the match cannot swallow the closing quote of the literal it sits
        -- in. The first version used [^\s]*, which ran to the end of the statement, turning
        -- ('SCRAM-SHA-256$AAAA$BBBB') into ('SCRAM-SHA-256$<redacted> with the bracket left dangling.
        --
        -- BOTH segments, separated by the second $. A verifier is SCRAM-SHA-256$<salt>$<stored key>,
        -- and the stored key is half the credential: redacting the salt alone would leave something
        -- that still verifies a password attempt. The trailing * is in the alphabet for the same
        -- reason PostgreSQL's own base64 alphabet has it.
        'SCRAM-SHA-256\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+',
        'SCRAM-SHA-256$<redacted>',
        'g'),
      -- An md5 verifier: 'md5' followed by 32 hex digits with no separator.
      'md5[0-9a-f]{32}',
      'md5<redacted>',
      'g'),
    '');
$redact$;

COMMENT ON FUNCTION @extschema@.lock_tree_redact(text) IS
  'Strip password literals, SCRAM verifiers and md5 hashes from query text before it is stored. '
  'Applied by lock_tree_sample() unless lock_tree.history_query says otherwise. Two statements '
  'differing only in a password group as one row afterwards, which is usually what you want.';

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_sample()
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  -- The CTE is what makes the return type work. A bare INSERT cannot be the body of a
  -- function returning bigint: SQL requires INSERT ... RETURNING, and RETURNING on a
  -- snapshot of a quiet database yields no rows at all, so the function would return zero
  -- rows rather than 0. Counting inside the CTE gives a row with 0 in it.
  --
  -- search_path is pinned because an unqualified table name cannot resolve under
  -- pg_catalog alone, so @extschema@.lock_tree_history below is qualified explicitly. Both
  -- details were found by trying it rather than by reasoning about it.
  -- Two independent inserts, and BOTH run even though only one is counted. A data-modifying CTE is
  -- executed exactly once whether or not anything selects from it, which is the property that lets
  -- the deadlock sample be written here without changing what this function returns.
  WITH observed AS (
    SELECT d.deadlocks
    FROM pg_stat_database d
    WHERE d.datname = current_database()
  ),
  previous AS (
    SELECT p.deadlocks
    FROM @extschema@.lock_tree_deadlock p
    ORDER BY p.sampled_at DESC
    LIMIT 1
  ),
  recorded AS (
    INSERT INTO @extschema@.lock_tree_deadlock
      (sampled_at, deadlocks, delta, counter_reset)
    SELECT statement_timestamp(),
           o.deadlocks,
           -- Floored, because pg_stat_reset_shared('db') sets the counter to zero and a negative
           -- delta would be nonsense. counter_reset records that it happened so the report can say
           -- the window total is not the sum of the deltas.
           greatest(o.deadlocks - coalesce(p.deadlocks, o.deadlocks), 0),
           p.deadlocks IS NOT NULL AND o.deadlocks < p.deadlocks
    FROM observed o
    LEFT JOIN previous p ON true
    ON CONFLICT (sampled_at) DO UPDATE
      SET deadlocks     = EXCLUDED.deadlocks,
          delta         = EXCLUDED.delta,
          counter_reset = EXCLUDED.counter_reset
    RETURNING 1
  ),
  written AS (
    INSERT INTO @extschema@.lock_tree_history
      (sampled_at, root_pid, depth, pid, state, waiting_for,
       wait_age, application_name, query, root_object, query_id)
    SELECT statement_timestamp(), lt.root_pid, lt.depth, lt.pid, lt.state, lt.waiting_for,
           lt.wait_age, lt.application_name,
           -- Redacted BEFORE truncation, not after, so that a password starting before character
           -- 300 is caught even though the text is cut there. Truncating first would leave a
           -- partial credential in the table for the length of a sample interval times the
           -- retention, which is the whole problem this fixes.
           --
           -- The setting has three values and the default is the safe one:
           --
           --   redacted   strip credentials                     (the default, and the fallback for
           --                                                         any value it does not recognise)
           --   none       store NULL
           --   full       store the query verbatim
           --
           -- A misspelling therefore redacts rather than leaks, which is the only direction an
           -- unrecognised value is allowed to fail in. Set it per session with
           --
           --   SET lock_tree.history_query = 'full';
           --
           -- or per database, which is how you would normally do it:
           --
           --   ALTER DATABASE mydb SET lock_tree.history_query = 'full';
           --
           -- There is no C code in this extension, so the setting is a placeholder GUC rather than
           -- a declared one, and it has no SHOW ALL entry until something sets it. That is why
           -- coalesce() rather than a bare current_setting(): an unset placeholder reads as NULL,
           -- and NULL must mean the safe default rather than an error or a leak.
           CASE coalesce(nullif(current_setting('lock_tree.history_query', true), ''), 'redacted')
             WHEN 'none'  THEN NULL
             WHEN 'full'  THEN left(coalesce(lt.query, ''), 300)
             ELSE left(@extschema@.lock_tree_redact(coalesce(lt.query, '')), 300)
           END,
           lt.root_object,
           -- Each row's OWN query_id, which is why the join is on pid rather than on root_pid.
           -- Joining on root_pid propagates the root's query_id down the whole chain, so every
           -- waiter looks like it was running the blocking statement, which is the normal case
           -- and would make the per-query totals wrong rather than merely incomplete.
           --
           -- What this means in practice: a query blocked on a lock has a NULL query_id for as
           -- long as it is blocked, so only depth-0 rows carry one. Same finding as
           -- lock_tree_statements(), and it is why this is per blocking query.
           ra.query_id
    FROM @extschema@.lock_tree lt
    -- A plain left join rather than a LATERAL subquery, because it is hashed once over the
    -- distinct pids instead of being evaluated per row. root_pid 0 is a prepared transaction,
    -- which is in no session at all and so matches nothing, which is correct.
    --
    -- The view is aliased as lt because pg_stat_activity also has a pid column, and with both in
    -- scope every unqualified pid in the select list is ambiguous.
    LEFT JOIN pg_stat_activity ra ON ra.pid = lt.pid
    RETURNING 1
  )
  SELECT count(*) FROM written
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sample() IS
  'Take one snapshot of the current lock tree into lock_tree_history. Returns the number of '
  'rows written, which is 0 when nothing is blocked. Schedule it; nothing calls it for you.';


-- Drop history older than a given age, returning how many rows went.
--
-- This exists because the table grows without bound otherwise: rows are only ever added,
-- and a wide queue at one sample a minute is 60 rows a minute for every session in it.
-- Pruning is a policy choice, so it is a parameter and not a scheduled job. A sensible
-- starting point is a day, or a week if you are chasing a rare one.
--
-- DELETE rather than TRUNCATE because TRUNCATE would take the whole table including rows
-- you wanted to keep.

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_summary()
RETURNS TABLE (
  blocked_sessions  bigint,
  roots             bigint,
  max_depth         int,
  longest_wait      interval,
  oldest_xact_age   interval
)
LANGUAGE sql STABLE
AS $$
  -- counts depth-0 rows, so this depends on the view having exactly one depth-0 row per root.
  -- That held until 0.8, when a prepared root stopped being merged with its peers and started
  -- being one row each: two prepared transactions went from roots = 1 to roots = 2, which is the
  -- correct answer and the reason for the change.
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

COMMENT ON COLUMN @extschema@.lock_tree_history.query_id IS
  'The root''s pg_stat_statements query_id, NULL on waiter rows. A query blocked on a lock has no '
  'query_id until it completes, so only roots carry one; see lock_tree_history_statements().';

COMMENT ON TABLE @extschema@.lock_tree_history IS
  'Sampled lock-wait trees, one row per session per sample. Empty until lock_tree_sample() '
  'is scheduled. Prune it with lock_tree_prune(); it grows by (sessions blocked) rows per sample. '
  'query_id is the ROOT''s pg_stat_statements query_id and is NULL on waiter rows, since a '
  'blocked query has no query_id until it completes; see lock_tree_history_statements().';

COMMENT ON FUNCTION @extschema@.lock_tree_notify_resolved(text, integer, integer, interval) IS
  'Raise one NOTIFY per root that had previously alerted and has now left the tree, with event = '
  '''cleared'', and forget the stored state so the next incident alerts again. Takes the same '
  'thresholds as lock_tree_notify() and keys on the same state, so the two read and write the same '
  'rows: use the same arguments on both or this reports resolutions for alerts that were never '
  'sent. A root that never alerted produces nothing. Returns how many it sent.';
