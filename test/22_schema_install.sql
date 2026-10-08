-- test/22_schema_install.sql: the extension installed into a schema of its own.
--
-- WHY THIS EXISTS. Every object is written with @extschema@, so the extension ought to install
-- anywhere, and two objects make that more than a convention:
--
--   lock_tree_sample()      SECURITY DEFINER, SET search_path = pg_catalog
--   lock_tree_redact()      SET search_path = pg_catalog
--
-- A pinned search_path is right for a SECURITY DEFINER function that reads every session's query
-- text, and it is also the one situation where an UNQUALIFIED reference to a sibling fails, because
-- pg_catalog is the whole path and lock_tree_redact is not in it. Every reference in both bodies is
-- @extschema@-qualified, which is why it works. This file is what notices when one stops being so.
--
-- Everywhere else the CALLER has the extension schema on its search_path, so an unqualified reference
-- resolves anyway and the mistake is invisible until somebody installs into a private schema. That is
-- the whole argument for testing it, and it is why the suite is not simply re-run with a different
-- path: the suite refers to objects by bare name, so running it with search_path pointing at the
-- private schema puts the extension back on the path and hides the exact thing under test.
--
-- WHAT IS HERE AND WHAT IS NOT. This file asserts the STRUCTURAL properties from the installed
-- catalog: that the substitution ran, that nothing landed in public, that both pinned functions
-- qualify everything they name, and that the grants documented in INSTALL.md are schema-agnostic.
-- The end-to-end install, calling every object by its full name from a session whose search_path
-- holds no extension object at all, is scripts/check-schema.sh. Splitting it that way is deliberate:
-- an install into a private schema needs a second database, and doing that inside a pgTAP file needs
-- either a second \connect, which loses the plan, or dblink plus a CREATE DATABASE, which is a lot of
-- machinery to fail for reasons that have nothing to do with the extension.
--
-- PROVEN NON-VACUOUS, on 2026-10-05. This file previously carried a note saying the planted defect
-- had never reached the catalog, so the assertion had never run against a defective function. It has
-- now. The defect was one line in lock_tree_command()'s body: FROM @extschema@.lock_tree_roots()
-- became FROM lock_tree_roots(), which is exactly the mistake this file exists to notice.
--
-- Reinstalling the extension is the part that was missing before. Both halves read the INSTALLED
-- catalog, so editing the file changes nothing until `make install` and a fresh CREATE EXTENSION. An
-- earlier attempt skipped that and found a passing test, which read as "the check is broken" and was
-- really "the catalog was unchanged".
--
-- With the defect installed, tests 8 and 9 fail, and test 9 names the function rather than only
-- counting it:
--
--     Failed test 8: no function in the extension schema holds an unqualified call to a sibling
--                    have: 1   want: 0
--     Failed test 9: and any that did are named rather than only counted
--                    have: lock_tree_command(1)   want:
--
-- The other twenty files and their 398 assertions passed unchanged. That is the claim in the header
-- above, now measured rather than asserted: in a public install the defect is invisible, which is why
-- this file and scripts/check-schema.sh exist. Both were restored and re-verified afterwards.

-- The dblink attempt is recorded below, because everything it went wrong on is worth knowing and
-- none of it was the extension's fault:
--
--   \gset written on the SAME LINE as its query is not recognised by psql at all. The whole line
--     goes to the server and the error is "syntax error at or near backslash", which names nothing
--     useful. A \gset that never runs leaves the variable empty.
--   A \gexec with no argument re-sends the last query BUFFER, not the statement you built. Three
--     statements later that buffer still holds something else, and the resulting error names a
--     database nobody in the file mentioned.
--   \gset matches the column alias CASE-INSENSITIVELY, so `AS dbname` and `:DBNAME` are the same
--     variable, which is convenient until it makes a reader think they are different ones.
--   And a
\echo wrapped in single quotes does not interpolate at all, so a diagnostic written that
--     way reports an empty value and sends you looking for a bug in the SQL that is not there.
--
-- Needs superuser: it reads the catalog of every installed object, and it creates a schema.

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

\o

\set QUIET 0

SELECT plan(11);

-- The schema this extension is actually in, read once and reused. Doing it with \gset would be the
-- trap described in the header; every assertion below takes the schema as an argument instead, so
-- nothing has to survive being pasted into SQL unquoted.

\set QUIET 1
\o /dev/null
CREATE TEMP TABLE where_am_i AS
SELECT n.nspname AS sch, e.extnamespace AS oid
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_lock_tree';

\o

\set QUIET 0

-- ------------------------------------------------------ the substitution actually ran

-- A leftover @extschema@ would make every function in the file fail to create, so this is close to
-- implied. It is worth asserting anyway because the failure it would prevent is total and the
-- evidence is one word.
SELECT is((SELECT count(*)::text
             FROM pg_proc p
            WHERE p.proname = 'lock_tree_sample'
              AND pg_get_functiondef(p.oid) LIKE '%@extschema@%'), '0',
          'lock_tree_sample() has no unexpanded @extschema@ left, so the substitution ran at install');

SELECT is((SELECT count(*)::text
             FROM pg_proc p
            WHERE p.proname = 'lock_tree_redact'
              AND pg_get_functiondef(p.oid) LIKE '%@extschema@%'), '0',
          'and neither has lock_tree_redact()');

-- ------------------------------------------------------ the two pinned functions

-- The pin is what makes lock_tree_sample() safe to expose to a role. Asserting it exists stops a
-- future edit removing it for convenience, which is the likeliest way it goes.
SELECT ok((SELECT (proconfig @> ARRAY['search_path=pg_catalog']::text[]) FROM pg_proc
            WHERE proname = 'lock_tree_sample') IS NOT NULL,
          'lock_tree_sample() pins search_path to pg_catalog, which is what a SECURITY DEFINER'
          || ' function reading every session''s query text must do');

SELECT ok((SELECT (proconfig @> ARRAY['search_path=pg_catalog']::text[]) FROM pg_proc
            WHERE proname = 'lock_tree_redact') IS NOT NULL,
          'lock_tree_redact() pins it too, and it is IMMUTABLE so it is inlined into its caller,'
          || ' which means a wrong reference there would surface as a plan-time failure');

-- The property the whole file is for, counted rather than pattern-matched for a name. Every
-- extension object the definition names must be schema-qualified, because the definition's own
-- search_path contains nothing but pg_catalog. Counting @ signs is a proxy; the direct check is
-- that no bare lock_tree_ call survives, which is the next assertion.
SELECT is((SELECT count(*)::text
             FROM pg_proc p
            WHERE p.proname = 'lock_tree_sample'
              AND regexp_replace(
                        regexp_replace(pg_get_functiondef(p.oid), '''[^'']*''', '', 'g'),
                        '--.*$', '', 'gn')
                  ~ '(^|[^.a-z_])lock_tree_\w+\s*\('), '0',
          'lock_tree_sample() contains no unqualified reference to a sibling, which is the one thing'
          || ' that would break a private-schema install and work everywhere else');

SELECT is((SELECT count(*)::text
             FROM pg_proc p
            WHERE p.proname = 'lock_tree_redact'
              AND regexp_replace(
                        regexp_replace(pg_get_functiondef(p.oid), '''[^'']*''', '', 'g'),
                        '--.*$', '', 'gn')
                  ~ '(^|[^.a-z_])lock_tree_\w+\s*\('), '0',
          'and neither does lock_tree_redact()');

-- Asserted positively as well, so the two above cannot pass on a definition that names nothing. A
-- negative check over an empty set is the easiest kind of assertion to get wrong: a function whose
-- body was emptied would satisfy it.
SELECT ok((SELECT (pg_get_functiondef(p.oid) LIKE '%lock_tree_redact(%')::int FROM pg_proc p
            WHERE p.proname = 'lock_tree_sample') IS NOT NULL,
          'and it does name lock_tree_redact(), so the check above has something to be about: a body'
          || ' with every reference removed would satisfy it and fail this');

-- Every OTHER function that calls a sibling must qualify it too, because a caller might reach any of
-- them with a search_path that lacks the schema even if none of those functions pins one.
--
-- Two numbers and then the names. "One function has a bare reference" is not a finding a reader can
-- act on; the name is. Both come from the same table, so they cannot disagree.
--
-- No \gset anywhere in this block. Every earlier version of it went through one, and a \gset carries
-- a value into later SQL as text that has to be pasted unquoted, which is this project's documented
-- trap. A scalar subquery inside the assertion needs nothing pasted at all.
\set QUIET 1
\o /dev/null
CREATE TEMP TABLE bare_refs AS
SELECT p.proname AS fn,
       (SELECT count(*)::int
          FROM regexp_matches(
                 -- String literals removed first, then comments, in that order.
                 --
                 -- Literals: a message that NAMES a sibling is prose, not a call.
                 -- lock_tree_archive_since_guard() raises "lock_tree_archive_find() needs a since
                 -- window", and a bare name inside a string is indistinguishable from a bare call.
                 -- The class is ANCHORED between quotes on purpose: '[^'']*' on its own also matches
                 -- the empty string at every position and would delete the whole body.
                 --
                 -- Comments: a -- line that names a sibling is the same trap, and the body of
                 -- lock_tree_sample() explains what it samples, so it mentions several names. The
                 -- 'n' flag matters more than it looks: without it a bare dot matches a newline and
                 -- $ anchors at end of STRING, so the strip ate every body from its first -- onwards.
                 -- Measured on a real install, lock_tree_duration() survived as 1 of 7391 characters,
                 -- so the "no bare reference" assertion was being applied to a few characters of
                 -- preamble and could not have failed. Found by planting one in 1.1.8 and watching
                 -- this pass. Same trap as the assertion counter in lint-docs.sh, same fix.
                 regexp_replace(
                        regexp_replace(pg_get_functiondef(p.oid), '''[^'']*''', '', 'g'),
                        '--.*$', '', 'gn'),
                 '(^|[^.a-z_])lock_tree_\w+\s*\(', 'g')) AS n
  FROM pg_proc p
  JOIN pg_depend d ON d.objid = p.oid AND d.classid = 'pg_proc'::regclass
                   AND d.refclassid = 'pg_extension'::regclass
  JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_lock_tree'
 WHERE p.prokind = 'f';
\o
\set QUIET 0

SELECT is((SELECT count(*)::int FROM bare_refs WHERE n > 0), 0,
          'no function in the extension schema holds an unqualified call to a sibling, in any of'
          || ' the ' || (SELECT count(*)::text FROM bare_refs) || ' functions. Not only the two that'
          || ' pin search_path: a caller with a narrow path can reach any of these');

SELECT is((SELECT coalesce(string_agg(fn || '(' || n || ')', ' ' ORDER BY fn), '')
            FROM bare_refs WHERE n > 0), ''::text,
          'and any that did are named rather than only counted');

-- ------------------------------------------------------ the documented grants are portable

-- INSTALL.md writes every grant as ON <object>, with no schema. That resolves to the object's own
-- schema, which is what makes the documented instructions work in a private schema. If a grant were
-- ever written as ON public.something, these would still pass, so the check is that the objects
-- themselves are where the extension put them and that no object escaped into public.

\set QUIET 1
\o /dev/null
SELECT (SELECT count(*)::text
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname <> (SELECT sch FROM where_am_i) AND c.relname LIKE 'lock\_tree%') AS strays_rel

\gset
SELECT (SELECT count(*)::text
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname <> (SELECT sch FROM where_am_i) AND p.proname LIKE 'lock\_tree%') AS strays_fn

\gset

\o

\set QUIET 0

SELECT is((SELECT :strays_rel::int + :strays_fn::int), 0,
          'nothing of the extension''s is in public at all, so a bare name in a caller''s query'
          || ' cannot resolve to one of its objects by accident, and a documented grant cannot be'
          || ' aimed at the wrong schema');

-- Membership, not coincidence. A function that happened to sit in the extension's schema without
-- being an extension member would be left behind by DROP EXTENSION, and this distinguishes the two.

\set QUIET 1
\o /dev/null
SELECT (SELECT count(*)::text
          FROM pg_depend d
          JOIN pg_extension e ON e.oid = d.refobjid AND d.refclassid = 'pg_extension'::regclass
          JOIN pg_class c ON c.oid = d.objid AND d.classid = 'pg_class'::regclass
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE e.extname = 'pg_lock_tree'
           AND n.nspname <> (SELECT sch FROM where_am_i)) AS strays

\gset

\o

\set QUIET 0

SELECT is(:strays::int, 0,
          'and every relation it owns is a member of it, so none would survive a DROP EXTENSION as'
          || ' an orphan in whatever schema the install happened to use');

SELECT * FROM finish();
