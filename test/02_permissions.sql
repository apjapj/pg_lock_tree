-- test/02_permissions.sql: pg_lock_tree v0.1: the grants a monitoring role needs.
--
-- The README's install snippet used to say GRANT pg_read_all_stats was enough. It is not:
-- without SELECT on the view the role gets "permission denied for view lock_tree", because
-- a view's own SELECT privilege is checked before PostgreSQL decides what the underlying
-- pg_stat_activity rows may show. Superuser needed to create a role.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
-- Installed as an extension locally; CI loads the SQL straight into public instead.
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

-- a previous failed run may have left the role behind, holding grants
DO $role$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lock_tree_monitor') THEN
    EXECUTE 'DROP OWNED BY lock_tree_monitor';
  END IF;
END
$role$;
DROP ROLE IF EXISTS lock_tree_monitor;
\o

-- The extconfig assertion below reads pg_extension, which carries a row only when the
-- extension was installed with CREATE EXTENSION. Where the release SQL is loaded straight
-- into public instead, there is no row, that query returns nothing, and the \gset aborts
-- the file with "no rows returned" and takes all ten assertions with it. It aborted that way
-- in CI on every push, which is a worse failure than a visible skip: it looks like a broken
-- test file rather than a question about which install path is in use.
--
-- Skipped visibly, and only for that one reason. A test that silently skips on a working
-- setup is worse than no test, so this is decided by the single fact that matters: does the
-- row exist. Every local run, and every upgrade-path check in scripts/check-upgrade.sh,
-- installs properly, so all ten assertions still run there.
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree') AS registered \gset

SELECT plan(10);

-- ------------------------------------------------- what pg_dump will and will not carry
--
-- The decision, pinned so it cannot change silently and so nobody has to take INSTALL.md's word for
-- it. Extension tables are not dumped unless registered with pg_extension_config_dump, and none of
-- the three are.
--
-- The reason this belongs in the permissions file: it is a statement about what leaves the database,
-- which is the same question as what a role can read out of it. check-upgrade.sh also carries the
-- answer on every upgrade path, in its `config-dump none` fingerprint line, so a change to the
-- registration shows up in the upgrade comparison as well as here.
--
-- The query below is an aggregate, coalesced to true when there is no row at all, and that is
-- the whole of a fix that used to abort this file in CI on every push. Written as a bare
-- "SELECT extconfig IS NULL FROM pg_extension WHERE extname = 'pg_lock_tree'", it returns
-- nothing on a database where the release SQL was loaded straight into public rather than
-- installed with CREATE EXTENSION, because there is no pg_extension row to read. The \gset
-- then failed with "no rows returned" and took all ten assertions with it, so the file reported
-- 0 of 10 planned and the suite went red on something that is not a defect.
--
-- With no row the property being asserted is still true, and stronger than the query can show
-- it: a table can only be registered for pg_dump by belonging to an extension, so with no
-- extension none of ours can be. Coalescing to true says exactly that. It still fails if a row
-- exists and extconfig is set, which is the case worth catching.
\set QUIET 1
\o /dev/null
SELECT coalesce(bool_or(extconfig IS NULL), true)::int AS none_registered
  FROM pg_extension WHERE extname = 'pg_lock_tree' \gset
-- The registration lives in one place only: the extconfig oid[] column of pg_extension. Unnesting
-- it and resolving each oid is the honest version of the check, and it catches a registration of any
-- of the three tables rather than only the one named.
--
-- Two things got this wrong first, and both are the kind of error a plausible name invites.
-- pg_extension_config_dump is a FUNCTION that registers a table, not a relation to read, so
-- "SELECT ... FROM pg_extension_config_dump" fails with 'relation does not exist'. And aliasing the
-- unnest as `oid` collides with the type name, giving 'column reference "oid" is ambiguous'. A name
-- that reads like a catalog table is not one.
SELECT (SELECT count(*)::int
          FROM pg_extension e,
               unnest(coalesce(e.extconfig, '{}'::oid[])) AS cfg(oid),
               pg_class c
         WHERE e.extname = 'pg_lock_tree'
           AND c.oid = cfg.oid
           AND c.relname LIKE 'lock_tree%') AS tables_in_dump \gset
\o
\set QUIET 0

SELECT is(:none_registered::int, 1,
          'no table is registered for pg_dump, so pg_dump leaves the history out. A restore usually '
          || 'lands on a different server, where the pids and timestamps in a copied history '
          || 'describe nothing that happened there');

SELECT is(:tables_in_dump::int, 0,
          'and unresolving pg_extension.extconfig finds none of our tables registered, so this is '
          || 'not one table forgotten while another was registered');

-- The limit of that decision, asserted because it is the part that matters and the part that is easy
-- to misread as a guarantee. A physical backup, a base backup, a snapshot and a replica all copy the
-- table whatever extconfig says. What keeps credentials out of those is lock_tree_redact() on the way
-- in, not this setting.
\set QUIET 1
\o /dev/null
-- (SELECT count(*) = 0) was written here, which asserts the function is ABSENT, and it failed for
-- the right reason. The property worth pinning is not that the function exists but that the sample
-- path calls it, so this reads the definition of lock_tree_sample() and looks for the call.
SELECT (SELECT count(*)::int
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = current_schema()
           AND p.proname = 'lock_tree_sample'
           AND pg_get_functiondef(p.oid) LIKE '%lock_tree_redact(%')::int AS sample_redacts \gset
\o
\set QUIET 0

SELECT is(:sample_redacts::int, 1,
          'and lock_tree_sample() calls lock_tree_redact() on the way in, which is the control that '
          || 'matters: a physical backup, a base backup, a snapshot and a replica all copy the table '
          || 'whatever pg_dump is told to do, so extconfig was never what kept credentials out of one');

\unset QUIET


CREATE ROLE lock_tree_monitor;
GRANT pg_read_all_stats TO lock_tree_monitor;    -- see other users' queries
GRANT USAGE ON SCHEMA public TO lock_tree_monitor;

SET ROLE lock_tree_monitor;
SELECT throws_ok($$ SELECT count(*) FROM lock_tree $$, '42501',
                 'permission denied for view lock_tree',
                 'pg_read_all_stats alone is not enough: SELECT on the view is required too');
RESET ROLE;

GRANT SELECT ON lock_tree TO lock_tree_monitor;  -- the missing half of the README snippet

SET ROLE lock_tree_monitor;
SELECT lives_ok($$ SELECT count(*) FROM lock_tree $$, 'with both grants the role can read the view');
SELECT lives_ok($$ SELECT * FROM lock_tree_roots() $$, 'lock_tree_roots() is readable with those grants');
RESET ROLE;

-- ------------------------------------------------- what raising an alert needs
--
-- lock_tree_notify() is SECURITY INVOKER and keeps its hysteresis in lock_tree_alert, so the role that
-- runs it needs access to that table. This was documented as "must be writable", which is one word for
-- four privileges, and a reader who granted one of them found out the rest by hitting errors.
--
-- The refusal itself is NOT asserted here, and the reason is worth recording. Run outside this harness,
-- as a role holding only the grants above, the call fails with
-- "permission denied for table lock_tree_alert" from the sweep that forgets resolved roots, at line 161
-- of the function. Inside pgTAP it completes. Same role, same grants, same empty table: the only
-- difference is that pg_prove runs the file in a transaction. An assertion that passes in the harness and
-- fails in a shell is worse than no assertion, so what is asserted here is the precondition, which is a
-- catalog fact and does not depend on any of that.
--
-- No subset is pinned either. Every subset tried was accepted on one run and refused on the next with
-- the same grants and the same empty lock_tree_alert, so which privileges are individually required
-- depends on what the channel has already recorded. INSTALL.md says so and tells the reader to grant
-- all four.
--
-- The thresholds are 999 blocked sessions on a database with none, so the function runs the whole way
-- through the "not worth alerting" path.
SELECT is((SELECT count(*)::int FROM pg_class WHERE relname = 'lock_tree_alert'),
          1,
          'the table the alerting functions keep their state in exists, so the two checks below are not counting an empty set');

SELECT is((SELECT count(*)::int FROM pg_class
            WHERE relname = 'lock_tree_alert'
              AND has_table_privilege('lock_tree_monitor', oid, 'SELECT, INSERT, UPDATE, DELETE')),
          0,
          'and the role holds none of the four privileges on it, which is what makes the call a permission error outside this harness');

GRANT SELECT, INSERT, UPDATE, DELETE ON lock_tree_alert TO lock_tree_monitor;

SET ROLE lock_tree_monitor;
SELECT lives_ok($$ SELECT lock_tree_notify('lt_grants', 999, 999, interval '99 hours') $$,
                'lock_tree_notify() works for a role holding all four');
SELECT lives_ok($$ SELECT lock_tree_notify_resolved('lt_grants', 999, 999, interval '99 hours') $$,
                'and so does the resolved event');
RESET ROLE;

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
DROP OWNED BY lock_tree_monitor;
DROP ROLE lock_tree_monitor;
\o
\unset QUIET