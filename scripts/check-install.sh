#!/usr/bin/env bash
# scripts/check-install.sh — verify a pg_lock_tree installation end to end.
#
# Walks the same checks as INSTALL.md's "Verify the install", so the documentation and
# something executable cannot drift apart. Exits non-zero on the first failure.
#
#   psql -X -f scripts/check-install.sql      # or: ./scripts/check-install.sh
#
# Override the connection with the usual libpq environment variables.

set -uo pipefail

PSQL=${PSQL:-psql}
DB=${PGDATABASE:-postgres}
: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
export PGHOST PGUSER PGDATABASE=$DB

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
fail=0

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { green "  ok    $1"; }
bad()  { red   "  FAIL  $1"; fail=1; }

server=$(psql -X -tAc 'SHOW server_version_num' 2>/dev/null || echo "")
if [ -z "$server" ]; then
    red "cannot connect to $DB as $PGUSER via ${PGHOST:-local socket}"
    echo "  INSTALL.md, Troubleshooting: 'Peer authentication failed for user postgres'"
    exit 2
fi

step "server"
echo "  version $((server / 10000)).$((server % 10000 / 100))  (needs >= 14)"
if [ "$server" -ge 140000 ]; then ok "PostgreSQL 14 or later"
else bad "PostgreSQL is older than 14; this extension needs pg_locks.waitstart"; fi

step "installed?"
ver=$(psql -X -tAc "SELECT extversion FROM pg_extension WHERE extname='pg_lock_tree'" 2>/dev/null)
if [ -z "$ver" ]; then
    bad "pg_lock_tree is not installed in this database"
    echo "  sudo -u postgres psql -c 'CREATE EXTENSION pg_lock_tree;'"
    exit 1
fi
ok "version $ver"
default=$(psql -X -tAc "SELECT default_version FROM pg_available_extensions WHERE name='pg_lock_tree'" 2>/dev/null)
if [ -n "$default" ] && [ "$ver" != "$default" ]; then
    echo "  note: $default is available; you have $ver"
    echo "        ALTER EXTENSION pg_lock_tree UPDATE;"
fi

step "objects"
schema=$(psql -X -tAc "SELECT n.nspname FROM pg_extension e
                       JOIN pg_namespace n ON n.oid = e.extnamespace
                       WHERE e.extname='pg_lock_tree'" 2>/dev/null)
echo "  schema: $schema"
[ -n "$schema" ] && ok "extension objects live in $schema" || bad "cannot determine schema"

# A view lands in pg_class and a function in pg_proc, so each name needs both checked.
# Summarise with a single aggregate rather than UNION ALL + head -1: UNION ALL returns two
# rows, so head -1 always saw the pg_class count (0 for a function) and reported every
# function as missing.
for f in lock_tree lock_tree_roots lock_tree_text lock_tree_text_short lock_tree_actions \
         lock_tree_age lock_tree_mode_short lock_tree_state_short; do
    found=$(psql -X -tAc "
        SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='$schema' AND c.relname='$f')
             + (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='$schema' AND p.proname='$f')" 2>/dev/null)
    if [ "${found:-0}" -gt 0 ] 2>/dev/null; then ok "$f"; else bad "$f missing"; fi
done

step "queries (0 rows is correct; an error is not)"
for q in "SELECT count(*) FROM $schema.lock_tree" \
         "SELECT count(*) FROM $schema.lock_tree_roots()" \
         "SELECT count(*) FROM $schema.lock_tree_text()" \
         "SELECT count(*) FROM $schema.lock_tree_text_short()" \
         "SELECT count(*) FROM $schema.lock_tree_actions()"; do
    out=$(psql -X -tAc "$q" 2>&1)
    if [ $? -eq 0 ]; then ok "$q  -> ${out:-0}"; else bad "$q  -> $out"; fi
done

step "settings"
mpt=$(psql -X -tAc 'SHOW max_prepared_transactions' 2>/dev/null)
if [ "${mpt:-0}" -gt 0 ] 2>/dev/null; then
    ok "max_prepared_transactions=$mpt (prepared-transaction path testable)"
else
    echo "  note: max_prepared_transactions=0, so test/04_prepared.sql will SKIP."
    echo "        Normal use of the extension is unaffected."
fi

step "result"
if [ $fail -eq 0 ]; then
    green "all checks passed"
    echo
    echo "  To see it working on a real blocking chain:  psql -X -f demo.sql"
    exit 0
else
    red "some checks failed — see INSTALL.md, Troubleshooting"
    exit 1
fi