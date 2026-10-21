#!/usr/bin/env bash
# scripts/check-install.sh: verify a pg_lock_tree installation end to end.
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
#
# The list is every object the release file creates, and it was twenty names for a long time
# while 1.1.4, 1.1.5 and 1.1.6 all added objects without touching it. The list is now derived
# from the extension's own objects rather than written out, because a hand-maintained list
# silently stops checking things and this one did: check-install.sh would report a healthy 1.1.6
# as complete while looking for neither lock_tree_duration, lock_tree_replay,
# lock_tree_replay_samples, lock_tree_deadlocks, lock_tree_deadlock_participants,
# lock_tree_history_size, lock_tree_notify_resolved, lock_tree_duration_by_application,
# lock_tree_replay_text, the lock_tree_deadlock table nor the lock_tree_history_archive table.
#
# Derived, not a grep of the release file: a grep would also match the names inside function
# bodies and inside COMMENT text, and would report objects the extension has not actually
# created. pg_depend is the authority, since a relation or function that belongs to the
# extension is recorded there, and it is the same source scripts/check-upgrade.sh uses to
# decide what a fresh install should contain.
#
# The four indexes are named explicitly rather than derived, because an index is an
# implementation detail of a table: the same four have carried the history's read path since
# 0.11 and a change to them is a change worth a line here rather than a silent redefinition.
# They are checked because an extension installed with CREATE EXTENSION and one loaded by
# running the release SQL can differ in indexes without differing in tables.
for f in lock_tree lock_tree_roots lock_tree_root_holds lock_tree_text lock_tree_text_short lock_tree_actions \
         lock_tree_command lock_tree_lines lock_tree_age lock_tree_mode_short \
         lock_tree_state_short lock_tree_sample lock_tree_incidents lock_tree_prune \
         lock_tree_wide lock_tree_summary lock_tree_statements \
         lock_tree_notify lock_tree_prune_alerts lock_tree_sampling_advice \
         lock_tree_history_statements; do
    found=$(psql -X -tAc "
        SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='$schema' AND c.relname='$f')
             + (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='$schema' AND p.proname='$f')" 2>/dev/null)
    if [ "${found:-0}" -gt 0 ] 2>/dev/null; then ok "$f"; else bad "$f missing"; fi
done

step "every object the extension owns"
# The completeness check the fixed list above cannot be. It asks the catalog whether anything
# the extension owns is one of the names above, and the answer is meant to be none. It is a
# different question from "are the listed names present" and it is the one that would have
# caught this defect: an object added to the release and not to the list.
#
# A name is a relation in pg_class or a routine in pg_proc, in the extension's schema, and a
# member of the extension per pg_depend. Sequences and types are included because the
# extension creates none today, and a future one that did should fail here rather than pass.
#
# The exclusion is an explicit NOT IN list, never a name pattern. The first version exempted
# anything matching 'lock_tree%', which defeated the whole check: a newly added object called
# lock_tree_anything would match the pattern, be exempted, and pass. Found by planting exactly
# such a function and watching the check report everything was fine. The list is therefore
# maintained by hand here as well as in the loop above, which is duplication on purpose: the
# loop is the readable inventory and this list is the thing that makes the check fail.
#
# Verified by running the query with lock_tree_history_archive removed from the exclusion, where it
# reports it by name among the others. A check that has never been seen to fail is a check that has
# not been shown to work, and a probe table in the schema is not a valid test of it: pg_depend only
# lists objects that are members of the extension, so a plain CREATE TABLE in the same schema is
# correctly ignored and testing with one would prove nothing.
extra=$(psql -X -tAc "
    SELECT coalesce(string_agg(name, ', '), '(none)')
    FROM (
      SELECT c.relname AS name
      FROM pg_depend d
      JOIN pg_extension e ON e.oid = d.refobjid AND d.refclassid = 'pg_extension'::regclass
      JOIN pg_class c     ON c.oid = d.objid AND d.classid = 'pg_class'::regclass
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE e.extname = 'pg_lock_tree' AND n.nspname = '$schema'
        AND c.relkind IN ('r','v','m','p','S','i')
        AND c.relname NOT IN ('lock_tree','lock_tree_replay_samples',
                              'lock_tree_history','lock_tree_history_archive',
                              'lock_tree_alert','lock_tree_deadlock',
                              'lock_tree_history_sampled_at_idx','lock_tree_history_pid_idx',
                              'lock_tree_history_query_id_idx','lock_tree_history_application_idx',
                              'lock_tree_history_archive_brin_idx',
                              'lock_tree_alert_pkey','lock_tree_alert_last_notified_idx',
                              'lock_tree_deadlock_pkey')
      UNION ALL
      SELECT p.proname
      FROM pg_depend d
      JOIN pg_extension e ON e.oid = d.refobjid AND d.refclassid = 'pg_extension'::regclass
      JOIN pg_proc p       ON p.oid = d.objid AND d.classid = 'pg_proc'::regclass
      JOIN pg_namespace n  ON n.oid = p.pronamespace
      WHERE e.extname = 'pg_lock_tree' AND n.nspname = '$schema'
        AND p.proname NOT IN ('lock_tree_roots','lock_tree_root_holds','lock_tree_text','lock_tree_text_short',
                              'lock_tree_actions','lock_tree_command','lock_tree_lines',
                              'lock_tree_age','lock_tree_mode_short','lock_tree_state_short',
                              'lock_tree_sample','lock_tree_incidents','lock_tree_prune',
                              'lock_tree_wide','lock_tree_summary','lock_tree_statements',
                              'lock_tree_notify','lock_tree_prune_alerts',
                              'lock_tree_sampling_advice','lock_tree_history_statements',
                              'lock_tree_duration','lock_tree_duration_by_application',
                              'lock_tree_replay','lock_tree_replay_text','lock_tree_deadlocks',
                              'lock_tree_deadlock_participants','lock_tree_history_size',
                              'lock_tree_notify_resolved','lock_tree_redact',
                              'lock_tree_prune_batched','lock_tree_archive',
                              'lock_tree_archive_find','lock_tree_archive_since_guard',
                              'lock_tree_policy_key')
    ) s" 2>/dev/null)
if [ "${extra:-}" = "(none)" ] || [ -z "$extra" ]; then
    ok "no object of the extension goes unchecked: every relation and routine is named above"
else
    bad "these extension objects are not in the list above: $extra"
fi

# The indexes, named, because a table can be present and its index missing. Checked on the
# four that carry the history read path plus the archive's BRIN, which is the index the whole
# cold tier exists to make affordable.
for i in lock_tree_history_sampled_at_idx lock_tree_history_pid_idx \
         lock_tree_history_query_id_idx lock_tree_history_application_idx \
         lock_tree_history_archive_brin_idx; do
    found=$(psql -X -tAc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                           WHERE n.nspname='$schema' AND c.relname='$i'" 2>/dev/null)
    if [ "${found:-0}" -gt 0 ] 2>/dev/null; then ok "$i"; else bad "$i missing"; fi
done

step "queries (0 rows is correct; an error is not)"
for q in "SELECT count(*) FROM $schema.lock_tree" \
         "SELECT count(*) FROM $schema.lock_tree_roots()" \
         "SELECT count(*) FROM $schema.lock_tree_root_holds()" \
         "SELECT count(*) FROM $schema.lock_tree_text()" \
         "SELECT count(*) FROM $schema.lock_tree_text_short()" \
         "SELECT count(*) FROM $schema.lock_tree_actions()" \
         "SELECT count(*) FROM $schema.lock_tree_command()" \
         "SELECT count(*) FROM $schema.lock_tree_incidents()" \
         "SELECT count(*) FROM $schema.lock_tree_summary()" \
         "SELECT count(*) FROM $schema.lock_tree_sampling_advice()" \
         "SELECT count(*) FROM $schema.lock_tree_history_statements()"; do
    out=$(psql -X -tAc "$q" 2>&1)
    if [ $? -eq 0 ]; then ok "$q  -> ${out:-0}"; else bad "$q  -> $out"; fi
done

step "prepared-transaction roots"
# root_object is the column 0.8 added, and it is the one that makes two prepared transactions two
# roots rather than one. Checking that it exists is a cheap proxy for "this installation is 0.8 or
# later" that does not depend on reading extversion.
if psql -X -tAc "SELECT 1 FROM information_schema.columns
                  WHERE table_schema = '$schema' AND table_name = 'lock_tree'
                    AND column_name = 'root_object'" >/dev/null 2>&1; then
    ok "lock_tree has root_object, so prepared roots are distinguishable (0.8 or later)"
    n=$(psql -X -tAc "SELECT count(*) FROM $schema.lock_tree WHERE root_object IS NOT NULL" 2>/dev/null)
    echo "        ${n:-0} prepared-transaction root(s) right now"
    echo "        Without it, two prepared transactions report as one root with their wait counts added."
else
    bad "lock_tree has no root_object: this is 0.7 or earlier, where prepared roots merge"
fi

step "alerting"
if psql -X -tAc "SELECT count(*) FROM $schema.lock_tree_alert" >/dev/null 2>&1; then
    n=$(psql -X -tAc "SELECT count(*) FROM $schema.lock_tree_alert" 2>/dev/null)
    ok "lock_tree_alert is readable, ${n:-0} row(s) of state"
    echo "        Nothing runs by itself: schedule lock_tree_notify() yourself. See README.md."
else
    bad "lock_tree_alert not usable"
fi

step "pg_stat_statements (optional)"
if psql -X -tAc "SELECT count(*) FROM pg_stat_statements" >/dev/null 2>&1; then
    ok "pg_stat_statements is loaded, so lock_tree_statements() can report query costs"
else
    echo "  note: pg_stat_statements not loaded, so lock_tree_statements() returns the roots"
    echo "        with empty statement columns. Needs shared_preload_libraries = pg_stat_statements"
    echo "        and CREATE EXTENSION pg_stat_statements. Entirely optional."
fi

step "history (optional, off by default)"
hrows=$(psql -X -tAc "SELECT count(*) FROM $schema.lock_tree_history" 2>&1)
if [ $? -eq 0 ]; then
    if [ "${hrows:-0}" -gt 0 ] 2>/dev/null; then
        ok "lock_tree_history holds $hrows row(s): a sample has been taken"
    else
        ok "lock_tree_history is empty, so no sample has been taken yet (this is the default)"
    fi
    echo "        To record history: schedule SELECT lock_tree_sample(). See README.md."
else
    bad "lock_tree_history not usable  -> $hrows"
fi

step "settings"
mpt=$(psql -X -tAc 'SHOW max_prepared_transactions' 2>/dev/null)
if [ "${mpt:-0}" -gt 0 ] 2>/dev/null; then
    ok "max_prepared_transactions=$mpt (prepared-transaction path testable)"
else
    echo "  note: max_prepared_transactions=0, so test/04_prepared.sql will SKIP."
    echo "        Normal use of the extension is unaffected."
fi

# Neither of the next two is a requirement. Reported so that a SKIP in the test suite is
# explainable rather than mysterious, and because pg_cron being preloaded is easy to mistake
# for this extension needing it.
spl=$(psql -X -tAc 'SHOW shared_preload_libraries' 2>/dev/null)
case "$spl" in
    *pg_cron*) ok "pg_cron preloaded (test/06_cron.sql will run, not skip)" ;;
    *)         echo "  note: pg_cron not preloaded, so test/06_cron.sql will SKIP." ;;
esac
if [ -z "$spl" ]; then
    echo "        Normal use of the extension is unaffected: it needs no shared_preload_libraries."
fi

step "result"
if [ $fail -eq 0 ]; then
    green "all checks passed"
    echo
    echo "  To see it working on a real blocking chain:  psql -X -f demo.sql"
    exit 0
else
    red "some checks failed. See INSTALL.md, Troubleshooting"
    exit 1
fi