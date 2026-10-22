#!/usr/bin/env bash
# scripts/check-uninstall.sh: the clean-drop contract, using ProbeKit v0.1.0.
#
# Creates a throwaway database, installs ProbeKit and pg_lock_tree, seeds history and alert rows,
# takes a ProbeKit snapshot, checks that a dependent view refuses the drop, drops the extension with
# no CASCADE, and asserts that nothing it owned survives. It then reinstalls to prove the name is
# usable. The database is dropped at the end.
#
# Needs: createdb/dropdb rights, and probekit.control plus probekit--0.1.0.sql in the server's
# extension directory. Set PROBEKIT_SQL to install them from a checkout first if needed.
set -euo pipefail

db="lock_tree_uninstall_check_$$"
cleanup() { dropdb --if-exists "$db" >/dev/null 2>&1 || true; }
trap cleanup EXIT

createdb "$db"
export PGDATABASE="$db"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION probekit;
CREATE EXTENSION pg_lock_tree;

INSERT INTO lock_tree_history (sampled_at, root_pid, depth, pid)
VALUES (now(), 1, 0, 1);
INSERT INTO lock_tree_alert (channel, policy, root_pid, first_seen)
VALUES ('uninstall_check', 'must', 1, now());

CREATE TABLE uninstall_before (doc jsonb);
INSERT INTO uninstall_before SELECT probekit.snapshot('{"run":"uninstall-check"}'::jsonb);
SQL

# A dependent user view must block a plain drop.
psql -X -q -v ON_ERROR_STOP=1 -c "CREATE VIEW uninstall_dependent AS SELECT * FROM lock_tree;"
if psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_lock_tree" >/dev/null 2>&1; then
    echo "FAIL: DROP EXTENSION succeeded with a dependent view" >&2
    exit 1
fi
psql -X -q -v ON_ERROR_STOP=1 -c "DROP VIEW uninstall_dependent;"

psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_lock_tree;"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $check$
DECLARE
  survivors int;
BEGIN
  SELECT count(*) INTO survivors
    FROM probekit.survivors((SELECT doc FROM uninstall_before), 'pg_lock_tree');
  IF survivors <> 0 THEN
    RAISE EXCEPTION 'extension-owned survivors after drop: %', survivors;
  END IF;
  IF to_regclass('public.lock_tree_history') IS NOT NULL
     OR to_regclass('public.lock_tree_history_archive') IS NOT NULL
     OR to_regclass('public.lock_tree_deadlock') IS NOT NULL
     OR to_regclass('public.lock_tree_alert') IS NOT NULL THEN
    RAISE EXCEPTION 'a history, archive, deadlock or alert table survived the drop';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree') THEN
    RAISE EXCEPTION 'pg_extension still has a pg_lock_tree row';
  END IF;
  RAISE NOTICE 'PASS: no extension-owned survivor, and every history/alert table is gone';
END
$check$;
SQL

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_lock_tree;"
psql -X -q -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM lock_tree;" >/dev/null
echo "PASS: pg_lock_tree reinstalls and lock_tree answers"
