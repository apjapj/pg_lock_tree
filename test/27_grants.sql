-- test/27_grants.sql: the grant matrix, pinned.
--
-- INSTALL.md says two grants are needed and that pg_read_all_stats alone is not enough. This file
-- pins the four roles the book and INSTALL.md describe against the four read entry points:
--
--   no grants                 denied by the view, even though the functions are PUBLIC
--   pg_monitor only           still denied: pg_monitor carries pg_read_all_stats, not SELECT
--   SELECT on the view only   the call runs, but other sessions are not visible
--   both grants               the tree, the text, the command and the sample
--
-- lock_tree_sample() is SECURITY DEFINER and its EXECUTE is revoked from PUBLIC, so it needs its own
-- grant; that is asserted separately.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS dblink;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

DROP TABLE IF EXISTS lt_grants_t;
CREATE TABLE lt_grants_t (id int);
INSERT INTO lt_grants_t VALUES (1);

DO $role$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['lt_grants_none','lt_grants_pgmon','lt_grants_select','lt_grants_both'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('DROP OWNED BY %I', r);
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END
$role$;
CREATE ROLE lt_grants_none;
CREATE ROLE lt_grants_pgmon IN ROLE pg_monitor;
CREATE ROLE lt_grants_select;
CREATE ROLE lt_grants_both IN ROLE pg_read_all_stats;
GRANT USAGE ON SCHEMA public TO lt_grants_none, lt_grants_pgmon, lt_grants_select, lt_grants_both;
GRANT SELECT ON lock_tree TO lt_grants_select, lt_grants_both;
GRANT SELECT ON lock_tree_history TO lt_grants_both;

-- One superuser blocker and one superuser waiter, so "other sessions" is a real other session and
-- not the role's own backend.
SELECT dblink_connect('lt_grants_blk', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_connect('lt_grants_wait', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('lt_grants_blk', 'BEGIN');
SELECT dblink_exec('lt_grants_blk', 'LOCK TABLE lt_grants_t IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('lt_grants_wait', 'SELECT count(*) FROM lt_grants_t');

DO $wait$
DECLARE i int;
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN (SELECT count(*) FROM lock_tree_roots()) > 0;
    PERFORM pg_sleep(0.05);
  END LOOP;
END
$wait$;
\o
\set QUIET 0

SELECT plan(13);

SELECT is((SELECT count(*)::int FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
            WHERE r.rolname = 'pg_monitor'
              AND m.member = (SELECT oid FROM pg_roles WHERE rolname = 'lt_grants_pgmon')
              AND m.admin_option = false), 1,
          'lt_grants_pgmon is a member of pg_monitor, so the next assertions are about pg_monitor and not an empty role');

SET ROLE lt_grants_none;
SELECT throws_ok($$ SELECT count(*) FROM lock_tree $$, '42501', 'permission denied for view lock_tree',
                 'no grants: the view is denied');
SELECT throws_ok($$ SELECT * FROM lock_tree_roots() $$, '42501', 'permission denied for view lock_tree',
                 'no grants: lock_tree_roots() is denied too, although the function is PUBLIC');
RESET ROLE;

SET ROLE lt_grants_pgmon;
SELECT throws_ok($$ SELECT count(*) FROM lock_tree $$, '42501', 'permission denied for view lock_tree',
                 'pg_monitor alone: still denied, because pg_monitor does not grant SELECT on the view');
RESET ROLE;

SET ROLE lt_grants_select;
SELECT lives_ok($$ SELECT * FROM lock_tree_roots() $$, 'SELECT only: lock_tree_roots() runs');
SELECT is((SELECT count(*)::int FROM lock_tree_roots()), 0,
          'SELECT only: and it shows no other session, so there is no tree to read');
RESET ROLE;

SET ROLE lt_grants_both;
SELECT cmp_ok((SELECT count(*)::int FROM lock_tree_roots()), '>', 0,
              'both grants: the blocked session is visible');
SELECT cmp_ok((SELECT count(*)::int FROM lock_tree_text()), '>', 0,
              'both grants: the text rendering has the root');
SELECT cmp_ok((SELECT count(*)::int FROM lock_tree_command()), '>', 0,
              'both grants: the command form has the root');
SELECT throws_ok($$ SELECT lock_tree_sample() $$, '42501',
                 'permission denied for function lock_tree_sample',
                 'the sample is not PUBLIC: it needs its own EXECUTE');
RESET ROLE;

GRANT EXECUTE ON FUNCTION lock_tree_sample() TO lt_grants_both;
SET ROLE lt_grants_both;
SELECT lives_ok($$ SELECT lock_tree_sample() $$, 'with EXECUTE the sample runs as the role');
RESET ROLE;

SELECT is((SELECT proconfig FROM pg_proc WHERE oid = 'lock_tree_sample()'::regprocedure)
            @> ARRAY['lock_timeout=1s'],
          true, 'the sampler cannot park behind a lock on the history table');

SELECT is((SELECT count(*)::int FROM lock_tree_roots() WHERE root_pid <> pg_backend_pid()), 1,
          'superuser: the same fixture shows one root that is not this session');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT dblink_exec('lt_grants_blk', 'ROLLBACK');
SELECT dblink_disconnect('lt_grants_blk');
SELECT dblink_disconnect('lt_grants_wait');
DROP TABLE lt_grants_t;
DROP OWNED BY lt_grants_none, lt_grants_pgmon, lt_grants_select, lt_grants_both;
DROP ROLE lt_grants_none, lt_grants_pgmon, lt_grants_select, lt_grants_both;
\o
\unset QUIET
