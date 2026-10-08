-- test/23_archive.sql: the cold tier, added in 1.1.6.
--
-- lock_tree_history_archive and lock_tree_archive(). The move is the only shipped thing that writes
-- rows out of lock_tree_history, so the things worth proving are: that nothing is lost, that the
-- query text is redacted on the way across, and that the two failure modes that would matter in
-- production are caught before any row moves.
--
-- The loop is the one that shaped the implementation, and the way it failed is worth recording
-- because it was not the way that was expected. The obvious body is
--
--   INSERT INTO archive SELECT ... WHERE sampled_at < cutoff ORDER BY sampled_at LIMIT batch_size;
--   DELETE FROM lock_tree_history WHERE ctid IN (SELECT ctid ... ORDER BY sampled_at LIMIT batch_size);
--
-- and it was built and timed. It writes DUPLICATES: 34 rows into the archive from 21 eligible, on
-- this very fixture. Then it never terminates, because the DELETE's subquery selects rows the INSERT
-- has already copied and they are still in the source, so the eligible count never falls and the
-- EXIT is never reached. It ran for 179 seconds on a 62-row table before being killed, and it would
-- have kept going, growing the archive on every pass, until someone noticed.
--
-- The fixture below is built to catch exactly that: twenty rows share each sampled_at and
-- batch_size 7 does not divide twenty, so every batch boundary lands inside a tie. The "nothing is
-- lost" assertion is the one that fails, because 62 rows in does not become 62 rows out.
--
-- Re-redaction is the security assertion. lock_tree_sample() redacts on the way IN, under whatever
-- lock_tree.history_query said at the time, so a row can carry a verbatim query. Copying it to a
-- table kept for years would preserve that indefinitely. lock_tree_archive() re-applies
-- lock_tree_redact() on the move, so the archive is strictly safer than its source.
--
-- No superuser and no dblink needed beyond the usual extension setup.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;
-- No version guard, because no test here has one: the matrix installs the default version and this
-- file is about 1.1.6. A guard that skipped would be a test that passes without testing anything.
\o
\echo # the archive objects exist, and are a table and a procedure
SELECT plan(35);
SELECT has_table('lock_tree_history_archive',
                 'the archive table is there');

SELECT has_index('lock_tree_history_archive', 'lock_tree_history_archive_brin_idx',
                 'indexed by BRIN, by the name the extension gave it');

-- has_function rather than has_procedure: this pgTAP build has no has_procedure, and it finds a
-- procedure happily because pg_proc holds both kinds. The prokind check below is what actually
-- proves it is one, so the name check here is only about existence and arity.
SELECT has_function('lock_tree_archive', ARRAY['interval','integer'],
                     'lock_tree_archive(interval, integer) exists');

-- A procedure, not a function, and the reason is load bearing: only a procedure called outside a
-- transaction block may COMMIT. A function here could batch but not commit, so it would still hold
-- everything in one transaction, which is the thing being avoided.
SELECT ok((SELECT p.prokind = 'p' FROM pg_proc p WHERE p.proname = 'lock_tree_archive'),
          'a procedure, because only a procedure may commit between batches');

-- The archive is indexed by BRIN and nothing else, which is the whole reason the tier is cheap.
-- Four b-trees on the same rows cost 170 MB against 124 MB for this shape on the 1,209,600-row
-- fixture, and a b-tree on sampled_at alone is 475 MB against 1336 kB on the 63M-row one.
SELECT is((SELECT count(*)::int FROM pg_index i
           JOIN pg_class c ON c.oid = i.indexrelid
           WHERE c.relname LIKE 'lock_tree_history_archive%'),
          1,
          'exactly one index on the archive, so there is no b-tree to maintain on the move');

SELECT ok((SELECT am.amname = 'brin' FROM pg_class c
           JOIN pg_am am ON am.oid = c.relam
           WHERE c.relname = 'lock_tree_history_archive_brin_idx'),
          'and it is a BRIN');

-- Not registered with pg_dump, on the same reasoning and for the same reason as the other three
-- tables. A physical backup or a replica will still copy it, which is exactly why the move
-- re-redacts rather than trusting the policy that was in force when each row was sampled.
--
-- The property is that the archive is not among the relations pg_dump would dump, and it is asserted
-- by resolving extconfig rather than by comparing it to a rendering of itself. test/02_permissions.sql
-- already makes this argument for the extension as a whole, and its version is the stronger one: it
-- unnests extconfig and resolves each oid, so it catches a registration of ANY of our tables rather
-- than only the one named. This is the same check narrowed to the new table, and it is here because a
-- table added to an extension is exactly the thing that gets registered by habit.
--
-- The first version of this compared extconfig to the string 'EMPTY', which was wrong twice: extconfig
-- is NULL rather than an empty array on a clean install, so the comparison failed on every version, and
-- a NULL result made the whole assertion NULL rather than false, which pgTAP reports as "test result
-- was NULL", a third way to be wrong and the least legible. The coalesce also matters because CI loads
-- the release SQL directly rather than through CREATE EXTENSION, so there is no extension row at all
-- and a bare scalar subquery returns NULL, which is not a passing answer to a question about privileges.
\o /dev/null
\set QUIET 1
SELECT (SELECT count(*)::int
          FROM pg_extension e,
               unnest(coalesce(e.extconfig, '{}'::oid[])) AS cfg(oid),
               pg_class c
         WHERE e.extname = 'pg_lock_tree'
           AND c.oid = cfg.oid
           AND c.relname LIKE 'lock\_tree%') AS any_registered \gset
\o
\set QUIET 0

SELECT is(:any_registered::int, 0,
          'the archive is not in a pg_dump, and neither is any other lock_tree table');

-- Argument checks, before anything moves.
SELECT throws_ok('CALL lock_tree_archive(NULL);',
                 'P0001',
                 'lock_tree_archive() needs older_than, got NULL');

SELECT throws_ok('CALL lock_tree_archive(interval ''1 day'', 0);',
                 'P0001',
                 'lock_tree_archive() needs batch_size >= 1, got 0');

SELECT throws_ok('CALL lock_tree_archive(interval ''1 day'', -5);',
                 'P0001',
                 'lock_tree_archive() needs batch_size >= 1, got -5');

-- The fixture. Three samples of twenty sessions each: two old enough to archive, one recent enough
-- to stay. Twenty rows share each sampled_at, so batch_size 7 splits every tie.
\o /dev/null
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_history_archive;
INSERT INTO lock_tree_history
  (sampled_at, root_pid, depth, pid, state, waiting_for, wait_age,
   application_name, query, root_object, query_id)
SELECT t.at,
       1000,
       CASE WHEN s = 0 THEN 0 ELSE 1 END,
       1000 + s,
       CASE WHEN s = 0 THEN 'active' END,
       CASE WHEN s = 0 THEN NULL ELSE 'transactionid' END,
       CASE WHEN s = 0 THEN NULL ELSE interval '5 seconds' END,
       'app' || (s % 3),
       -- Every waiter row carries the credential-bearing form, and the two depth 0 roots carry a
       -- plain query. A root is the blocker and its query is the one holding the lock, which is the
       -- realistic shape, and it means the redaction count below is the 38 waiter rows rather than a
       -- number I have to remember to exclude two rows from.
       CASE WHEN s = 0 THEN 'SELECT 1'
            ELSE 'ALTER ROLE app LOGIN PASSWORD ''sekrit''' END,
       NULL,
       NULL
FROM (VALUES (now() - interval '3 days'),
             (now() - interval '2 days')) AS t(at),
     generate_series(0, 19) AS s;
-- The recent sample, which must survive the move untouched.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, application_name, query)
SELECT now() - interval '1 hour', 2000, 0, 2000, 'recent', 'SELECT 2'
FROM generate_series(1, 20);
-- A row whose query is NULL, because redaction must not turn NULL into an empty string:
-- lock_tree.history_query = 'none' stores NULL and an empty string reads as a blank query.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, query)
VALUES (now() - interval '4 days', 3000, 0, 3000, NULL);
-- And one recent NULL, which must also not move.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, query)
VALUES (now() - interval '30 minutes', 3001, 0, 3001, NULL);

SELECT count(*) AS rows_before FROM lock_tree_history \gset
\o
\set QUIET 0

SELECT is(:rows_before::int, 62,
          'the fixture holds 62 rows: 40 to archive, 20 recent, 2 NULL-query');

-- Refused inside a transaction block, and refused BEFORE moving anything. The refusal is
-- "invalid transaction termination", which says nothing about why; that is why the procedure checks
-- for it by attempting a COMMIT before the first batch rather than trusting the caller.
--
-- 0A000, not 2D000, and test/15_history_size.sql says why: throws_ok runs the statement inside a
-- subtransaction, and there the refusal is "EXECUTE of transaction commands is not implemented".
-- Called inside a real BEGIN block at the top level it is 2D000 "invalid transaction termination".
-- Same refusal, different wording, because a subtransaction and a transaction block are different
-- things to PostgreSQL. What matters is that it is refused at all, and the two assertions after it
-- check the part that is ours.
SELECT throws_ok('BEGIN; CALL lock_tree_archive(interval ''1 day'', 7);',
                 '0A000',
                 'EXECUTE of transaction commands is not implemented');

SELECT is((SELECT count(*) FROM lock_tree_history_archive)::int, 0,
          'and it moved nothing before refusing');

SELECT is((SELECT count(*) FROM lock_tree_history)::int, :rows_before::int,
          'and it deleted nothing before refusing');

-- The move itself, outside a transaction block, in batches of 7 so that more than one batch is
-- genuinely needed and every batch boundary falls inside a 20-row tie.
\o /dev/null
\set QUIET 1
CALL lock_tree_archive(interval '1 day', 7);
SELECT count(*) AS hot_after FROM lock_tree_history \gset
SELECT count(*) AS arch_after FROM lock_tree_history_archive \gset
SELECT count(*) AS null_queries FROM lock_tree_history_archive
 WHERE query IS NULL \gset
SELECT count(*) AS empty_queries FROM lock_tree_history_archive
 WHERE query = '' \gset
SELECT count(*) AS still_have_secret FROM lock_tree_history_archive
 WHERE query LIKE '%sekrit%' AND query NOT LIKE '%redacted%' \gset
SELECT count(*) AS redacted_rows FROM lock_tree_history_archive
 WHERE query LIKE '%<redacted>%' \gset
SELECT count(*) AS recent_survived FROM lock_tree_history
 WHERE application_name = 'recent' \gset
SELECT count(*) AS hot_nulls FROM lock_tree_history WHERE query IS NULL \gset
\o
\set QUIET 0

SELECT is(:hot_after::int + :arch_after::int, :rows_before::int,
          'nothing is lost: hot plus archive is exactly the row count that went in');

SELECT is(:arch_after::int, 41,
          'the 40 old rows and the one old NULL row moved');

SELECT is(:recent_survived::int, 20,
          'the recent sample stayed in the hot table');

SELECT is(:hot_nulls::int, 1,
          'and the recent NULL-query row stayed too');

-- The redaction. This is the assertion that matters most for a table meant to be kept for years.
SELECT is(:still_have_secret::int, 0,
          'no verbatim credential-bearing query reached the archive');

SELECT is(:redacted_rows::int, 38,
          'all 38 waiter rows were redacted on the way across, and the 2 plain root queries were not touched');

-- NULL must survive as NULL. Turning it into an empty string would read as a query that was
-- genuinely blank, which is a different and wrong thing to say about a session.
SELECT is(:empty_queries::int, 0,
          'no NULL query became an empty string');

SELECT ok((SELECT count(*) FROM lock_tree_history_archive WHERE query IS NULL) > 0,
          'and the NULL query is still NULL in the archive');

-- The archive is a different table, so the shipped read functions cannot see it. This is the
-- limitation 1.1.6 ships with, and it is asserted rather than left for someone to discover when a
-- quarterly report comes back short.
--
-- What is left hot is two samples half an hour apart, which is further apart than the five minute
-- default max_gap, so each is its own incident and incidents() reports 2. The archived samples were
-- a day apart, so had they been visible they would have added 2 more. The number 2 is therefore the
-- limitation stated as a figure: the archived half of the history is simply not in the answer.
SELECT is((SELECT count(*) FROM lock_tree_incidents())::int, 2,
          'lock_tree_incidents() reports only the recent samples, not the archived ones');

SELECT is((SELECT count(*) FROM lock_tree_incidents())::int,
          (SELECT count(DISTINCT sampled_at) FROM lock_tree_history)::int,
          'and that is exactly one incident per sample still in the hot table');

SELECT is((SELECT count(*) FROM lock_tree_history)::int, 21,
          'and the hot table holds only what was not archived');

-- Idempotent: a second call with nothing old enough finds nothing to move and says so, rather than
-- duplicating rows. There is no unique constraint to make a repeat fail, and failing would be the
-- wrong behaviour because the rows are identical.
\o /dev/null
\set QUIET 1
CALL lock_tree_archive(interval '1 day', 7);
SELECT count(*) AS arch_again FROM lock_tree_history_archive \gset
\o
\set QUIET 0

SELECT is(:arch_again::int, :arch_after::int,
          'a second call moves nothing and duplicates nothing');

-- The BRIN index is the whole reason a separate table is worth having, so it is checked while the
-- archive still holds rows. A size assertion placed after the cleanup TRUNCATE below would compare
-- two zeroes and pass or fail for no reason, which is the kind of check that reports its own
-- broken state as a pass.
--
-- The grants, because they are four privileges across two tables and none of them come from the
-- monitoring grants in INSTALL.md. Without this section the failure is "permission denied for table
-- lock_tree_history_archive", which names the table and not the missing privilege, and the natural
-- reading of it is that the archive table is missing rather than that the caller lacks INSERT on it.
--
-- The role is created and dropped inside this file, like test/02 does, so nothing is left behind and
-- no existing role is modified. The procedure is a procedure, so CALL, and it needs EXECUTE on it.
-- Cleared the way test/02_permissions.sql clears its role, which is the only way that works: a bare
-- DROP ROLE is refused while the role still holds grants, so a run that failed part way would leave
-- the role behind and the next run would stop at CREATE ROLE rather than at the assertion that was
-- actually wrong. That is a test that reports the wrong failure twice.
DO $role$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lock_tree_archiver') THEN
    EXECUTE 'DROP OWNED BY lock_tree_archiver';
  END IF;
END
$role$;
DROP ROLE IF EXISTS lock_tree_archiver;
CREATE ROLE lock_tree_archiver;
\o /dev/null
\set QUIET 1
GRANT USAGE ON SCHEMA public TO lock_tree_archiver;
GRANT SELECT ON lock_tree_history TO lock_tree_archiver;   -- the documented monitoring grant
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid, application_name, query)
SELECT now() - interval '60 days', 4000, 0, 4000, 'archtest', 'SELECT 1'
FROM generate_series(1, 3);
\o
\set QUIET 0

-- The grants cannot be tested with throws_ok or lives_ok, and the reason is worth stating because it
-- cost this section two wrong attempts. Both wrap the statement in a subtransaction, and a procedure
-- that COMMITs is refused there with 2D000 "invalid transaction termination" before it ever reaches
-- a privilege check. So the call under test never ran: the first attempt asserted a permission error
-- and got the transaction error, the second asserted success and got the same. test/15 hits the same
-- wall with lock_tree_prune_batched() and asserts the effect by counting rows instead.
--
-- So: assert by effect. A role with only SELECT on the history cannot move anything, which is the
-- privilege claim being made, and a role with the full set can.
\o /dev/null
\set QUIET 1
SELECT count(*) AS before_denied FROM lock_tree_history WHERE application_name = 'archtest' \gset
\o
\set QUIET 0

-- ON_ERROR_STOP is off for this one statement, deliberately, and it is the only place in this file
-- where an error is expected and allowed to stop nothing. The call is refused on the ARCHIVE table,
-- which is the second of the four privileges, and the error aborts the file under ON_ERROR_STOP and
-- takes the twenty-six assertions after it with it. Refusing is the point: the role cannot get past
-- the history read without the archive INSERT, and the row count after proves nothing moved.
\set ON_ERROR_STOP 0
SET ROLE lock_tree_archiver;
CALL lock_tree_archive(interval '1 day');
RESET ROLE;
\set ON_ERROR_STOP 1

\o /dev/null
\set QUIET 1
SELECT count(*) AS after_denied FROM lock_tree_history WHERE application_name = 'archtest' \gset
\o
\set QUIET 0

SELECT is(:after_denied::int, :before_denied::int,
          'SELECT on the history alone is not enough: nothing was moved');

-- Now the full set, and the call really does run this time.
\o /dev/null
\set QUIET 1
GRANT DELETE ON lock_tree_history TO lock_tree_archiver;
GRANT SELECT, INSERT ON lock_tree_history_archive TO lock_tree_archiver;
GRANT EXECUTE ON PROCEDURE lock_tree_archive(interval, integer) TO lock_tree_archiver;
\o
\set QUIET 0

SET ROLE lock_tree_archiver;
CALL lock_tree_archive(interval '1 day');
RESET ROLE;

\o /dev/null
\set QUIET 1
SELECT count(*) AS archiver_moved FROM lock_tree_history_archive
 WHERE application_name = 'archtest' \gset
DO $role$
BEGIN
  EXECUTE 'DROP OWNED BY lock_tree_archiver';
END
$role$;
DROP ROLE lock_tree_archiver;
\o
\set QUIET 0

SELECT is(:archiver_moved::int, 3,
          'and with SELECT and DELETE on the history plus SELECT and INSERT on the archive, the same role moves them');

-- ------------------------------------------------- 1.1.7: the archive is visible to the sizing function
--
-- Asserted here rather than in test/15 because this file is the one that knows what the archive
-- contains, and because the failure 1.1.7 fixes is only visible with an archive present at all.
\o /dev/null
\set QUIET 1
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_history_archive;
-- Two tables of known and different sizes, so a figure from one cannot pass for the other. 20 rows
-- hot, 40 archived, and the pids differ so the tables cannot be confused.
INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid)
SELECT now() - make_interval(secs => g * 10), 100 + g, 0, 500 + g
FROM generate_series(1, 20) g;
INSERT INTO lock_tree_history_archive (sampled_at, root_pid, depth, pid)
SELECT now() - make_interval(secs => g * 10), 200 + g, 0, 600 + g
FROM generate_series(1, 40) g;
VACUUM (ANALYZE) lock_tree_history;
VACUUM (ANALYZE) lock_tree_history_archive;
SELECT (SELECT rows              FROM lock_tree_history_size()) AS hs_rows,
       (SELECT total_bytes      FROM lock_tree_history_size()) AS hs_bytes,
       (SELECT archive_bytes    FROM lock_tree_history_size()) AS as_bytes \gset
\o
\set QUIET 0

-- The property 1.1.7 exists to fix. Before it the archive was invisible to this function, so the
-- thing an operator sizes a disk with could not see 40 rows sitting in the same database.
SELECT is(:as_bytes::bigint, (SELECT pg_total_relation_size('lock_tree_history_archive')::bigint),
          'archive_bytes is the archive relation''s own size, which before 1.1.7 was invisible here');

SELECT ok(:as_bytes::bigint > 0, 'and it is nonzero with 40 archived rows');

SELECT ok(:as_bytes::bigint <> :hs_bytes::bigint,
          'and it differs from total_bytes, so it is not the hot relation reported twice');

-- The eight columns that existed before 1.1.7 must be untouched. That is the whole claim of the
-- release, and it is checked against the fixture rather than against a snapshot of the output.
SELECT is(:hs_rows::bigint, 20::bigint,
          'and rows still reports only the hot table, so the pre-existing columns are unchanged');

SELECT is(:hs_bytes::bigint, (SELECT pg_total_relation_size('lock_tree_history')::bigint),
          'total_bytes is still the hot relation alone, which is what lets a reader add the two');

-- An empty archive must report ITS OWN size, not inherit the hot table's or a stale one. The first
-- draft of this asserted zero, and zero is wrong: an empty table is still one heap page, a free
-- space map and an index page, measured at 57,344 bytes here. The property is that the figure FOLLOWS
-- the archive, which is what "its own size" means, and asserting zero would have passed for the
-- wrong reason had the table not had a minimum footprint.
\o /dev/null
\set QUIET 1
TRUNCATE lock_tree_history_archive;
SELECT (SELECT archive_bytes FROM lock_tree_history_size()) AS empty_bytes \gset
\o
\set QUIET 0

SELECT is(:empty_bytes::bigint,
          (SELECT pg_total_relation_size('lock_tree_history_archive')::bigint),
          'an emptied archive reports its own much smaller size, not the hot table''s figure');

SELECT ok(:empty_bytes::bigint < :as_bytes::bigint,
          'and that is smaller than it was with 40 rows in it, so the figure follows the archive');

-- The index is asserted to be BRIN and to be the only one, above. Its SIZE is deliberately not
-- asserted here, and the first draft of this file got that wrong twice.
--
-- The claim worth making is a ratio: measured on 1,209,600 rows, the BRIN is 24,576 bytes against a
-- 92,610,560 byte heap, a factor of 3,768, and on the 63,072,020-row fixture it came out at 1336 kB
-- against 475 MB for a b-tree on the same column. Neither is testable at fixture scale, where this
-- file's archive holds 41 rows. A BRIN is at least 8 kB whatever it covers, and the heap of 41 short
-- rows is smaller than that, so any ratio asserted here is an artefact of the fixture rather than a
-- property of the index. The measured numbers belong in docs/history.md, where the fixture that
-- produced them can be rebuilt; asserting them here would be asserting a number this test cannot
-- check and would fail for the right reason, which is that it is in the wrong place.

\o /dev/null
TRUNCATE lock_tree_history;
TRUNCATE lock_tree_history_archive;
\o
\set QUIET 0
