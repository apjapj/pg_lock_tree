-- test/02_permissions.sql — pg_lock_tree v0.1: the grants a monitoring role needs.
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
\unset QUIET

SELECT plan(3);

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

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
DROP OWNED BY lock_tree_monitor;
DROP ROLE lock_tree_monitor;
\o
\unset QUIET