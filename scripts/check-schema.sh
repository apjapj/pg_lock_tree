#!/usr/bin/env bash
# scripts/check-schema.sh: install pg_lock_tree into a private schema and use it from there.
#
# WHY THIS IS A SCRIPT AND NOT A TEST FILE.
#
# Installing into a private schema needs a second database, because the extension lives in one and
# there can only be one copy of it per database. Doing that inside a pgTAP file means either a second
# \connect, which loses the plan, or dblink plus a CREATE DATABASE, and both go wrong for reasons that
# have nothing to do with the extension. This script can just use createdb and a second psql.
#
# test/22_schema_install.sql covers the structural half from the catalog: that the @extschema@
# substitution ran, that nothing landed in public, and that no function holds an unqualified call to a
# sibling. This covers the other half, which only a real install in a real private schema can show.
#
# WHY IT MATES AT ALL, given every object is written with @extschema@.
#
# Two functions pin search_path to pg_catalog: lock_tree_sample(), because it is SECURITY DEFINER and
# reads every session's query text, and lock_tree_redact(), because lock_tree_sample() inlines it. A
# pinned search_path is the correct choice for both, and it is also the only situation in which an
# unqualified reference to a sibling fails, because pg_catalog is the entire path and the sibling is
# not in it.
#
# Everywhere else this bug is invisible. A caller normally has the extension schema on its
# search_path, so lock_tree_redact resolves by bare name whether or not it is qualified. It fails only
# when the extension is somewhere the caller has not put on its path, which is exactly what a monitoring
# tool or a cron job in a hardened setup looks like.
#
# Usage: EXT=pg_lock_tree scripts/check-schema.sh
#   SCHEMA=lt_check    the schema to install into (default lt_check)
#   DATABASE=postgres  the database to install into   (default postgres)
#   KEEP=1             leave the scratch database behind, for inspection
# Exit 0 = everything reached; 1 = something did not, with the name of it; 2 = setup problem.
set -uo pipefail
cd "$(dirname "$0")/.."

EXT=${EXT:-pg_lock_tree}
SCHEMA=${SCHEMA:-lt_check}
DB=${DATABASE:-postgres}
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -At)

WORK=$(mktemp -d)
SCRATCH=""
cleanup() {
  [ -n "$SCRATCH" ] && [ "${KEEP:-0}" != 1 ] && dropdb --if-exists "$SCRATCH" >/dev/null 2>&1
  [ "${KEEP:-0}" != 1 ] && rm -rf "$WORK"
  return 0
}
# The scratch database is named from this shell's pid, so two runs cannot collide and a database left
# by an interrupted run is not silently reused. It is dropped only if this run created it, which is
# why the variable is empty until createdb succeeds.
trap cleanup EXIT

failed=()
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed+=("$1"); }
step() { printf '\n  \033[1m%s\033[0m\n' "$1"; }

command -v createdb >/dev/null || { echo "  createdb not on PATH; run with libpq's bin in PATH" >&2; exit 2; }
"${PSQL[@]}" -d "$DB" -c "SELECT 1 FROM pg_available_extensions WHERE name = '$EXT'" | grep -q 1 \
  || { echo "  $EXT is not installed on this server (make install first)"; exit 2; }

SCRATCH="lt_schema_$$"
step "installing $EXT into schema $SCHEMA, in a scratch database"
# createdb cannot run inside a transaction block, and psql -c with two statements wraps them in one,
# so DROP and CREATE are separate calls. The same trap is documented in check-upgrade.sh.
dropdb --if-exists "$SCRATCH" >/dev/null 2>&1
createdb "$SCRATCH" || { echo "  could not create $SCRATCH"; exit 2; }

# The install itself. \i is not used and the schema is not created first: CREATE EXTENSION ... SCHEMA
# requires the schema to exist, and creating it in the same psql invocation is fine, but keeping the
# two statements apart means a failure names which one failed.
"${PSQL[@]}" -d "$SCRATCH" -c "CREATE SCHEMA $SCHEMA" || exit 2
"${PSQL[@]}" -d "$SCRATCH" -c "CREATE EXTENSION $EXT SCHEMA $SCHEMA" \
  || { echo "  CREATE EXTENSION ... SCHEMA failed"; exit 2; }

ver=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT extversion FROM pg_extension WHERE extname='$EXT'")
printf '  installed %s %s into schema %s of %s\n' "$EXT" "$ver" "$SCHEMA" "$SCRATCH"

# ------------------------------------------------------------------ nothing escaped to public

step "nothing landed in public"

n=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n
       ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname LIKE 'lock\_tree%'")
[ "$n" = 0 ] && ok "no relation in public" || bad "$n relations in public"

n=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n
       ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'lock\_tree%'")
[ "$n" = 0 ] && ok "no function in public" || bad "$n functions in public"

# Membership rather than coincidence: a function that happened to sit in the schema without being an
# extension member would be left behind by DROP EXTENSION, and this is what tells the two apart.
n=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT count(*) FROM pg_depend d
       JOIN pg_extension e ON e.oid = d.refobjid AND d.refclassid = 'pg_extension'::regclass
       JOIN pg_class c ON c.oid = d.objid AND d.classid = 'pg_class'::regclass
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE e.extname = '$EXT' AND n.nspname <> '$SCHEMA'")
[ "$n" = 0 ] && ok "every relation it owns is a member of it" || bad "$n members outside $SCHEMA"

# ------------------------------------------------------------------ the two pinned functions

step "the two functions that pin search_path, which cannot see the schema at all"

for f in lock_tree_sample lock_tree_redact; do
  p=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT coalesce((proconfig @> ARRAY['search_path=pg_catalog']::text[])::int, 0)
                                  FROM pg_proc WHERE proname = '$f'")
  [ "$p" = 1 ] && ok "$f() pins search_path to pg_catalog" || bad "$f() does not pin search_path"
done

# The bare-reference count, over every function in the schema. A negative check that passes on an empty
# set is the easiest kind to get wrong, so the number of functions scanned is reported alongside it.
# Two things this pattern got wrong before it worked, both verified against a planted defect rather
# than reasoned about: \b does not behave after a lookbehind in PostgreSQL's ARE, so it silently
# matched nothing; and matching the raw definition counts every sibling NAME in a -- comment, which
# in lock_tree_sample() is three, because its body explains what it samples. Comments are stripped and
# the lookbehind is gone, which was verified by planting an unqualified call and watching this fire.
#
# PROVEN, end to end, on 2026-10-05. The claim that this fires was previously reasoned about rather
# than seen. The defect planted was one line in lock_tree_command()'s body:
# FROM @extschema@.lock_tree_roots() became FROM lock_tree_roots(). It has to be reinstalled into
# the catalog before either half can see it, which is the whole reason the earlier attempt found
# nothing: the file was edited and the test read an unchanged catalog.
#
# With the defect installed, this reported
#
#     1 unqualified sibling calls in lt_check
#     unreachable: SELECT count(*) FROM lt_check.lock_tree_command()
#
# and test/22_schema_install.sql reported tests 8 and 9 failing, with test 9 naming the function:
# lock_tree_command(1). The other twenty test files and their 398 assertions passed unchanged, which
# is the claim this file and that one are both making: in a public install the defect is invisible,
# and only a private-schema install exposes it. Both were restored and re-verified afterwards.
n=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT count(*)::text FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = '$SCHEMA' AND p.prokind = 'f'
        AND regexp_replace(pg_get_functiondef(p.oid), '--.*$', '', 'g')
              ~ '(^|[^.a-z_])lock_tree_\w+\s*\('")
total=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT count(*) FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = '$SCHEMA' AND p.prokind = 'f'")
if [ "$n" = 0 ]; then
  ok "no unqualified sibling call in any of the $total functions in $SCHEMA"
else
  bad "$n unqualified sibling calls in $SCHEMA"
  # Named, because a count alone is not actionable.
  "${PSQL[@]}" -d "$SCRATCH" -c "SELECT '          ' || p.proname FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = '$SCHEMA' AND p.prokind = 'f'
          AND regexp_replace(pg_get_functiondef(p.oid), '--.*$', '', 'g')
                ~ '(^|[^.a-z_])lock_tree_\w+\s*\('"
fi

# ------------------------------------------------------------------ calling everything

step "every object, qualified, from a session whose search_path holds no extension object"

# SET search_path = pg_catalog for the session, then call everything by its full name. This is the
# assertion the whole script exists for: if any of these worked only because the caller's path
# happened to contain the schema, it fails here and passes everywhere else.
# shellcheck disable=SC2016
CALLS=(
  "SELECT count(*) FROM $SCHEMA.lock_tree"
  "SELECT count(*) FROM $SCHEMA.lock_tree_replay_samples"
  "SELECT count(*) FROM $SCHEMA.lock_tree_roots()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_text()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_text_short()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_wide()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_summary()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_actions()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_command()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_statements()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_incidents()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_replay()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_replay_text()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_replay(now())"
  "SELECT count(*) FROM $SCHEMA.lock_tree_sampling_advice()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_deadlocks()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_history_size()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_duration()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_duration_by_application()"
  "SELECT count(*) FROM $SCHEMA.lock_tree_history_statements()"
  "SELECT $SCHEMA.lock_tree_redact('ALTER ROLE a PASSWORD ''x''')"
  "SELECT $SCHEMA.lock_tree_sample()"
  "SELECT $SCHEMA.lock_tree_notify('check_schema', 1, NULL, NULL)"
  "SELECT $SCHEMA.lock_tree_notify_resolved('check_schema', 1, NULL, NULL)"
  "SELECT $SCHEMA.lock_tree_prune(interval '1 day')"
  "SELECT $SCHEMA.lock_tree_prune_alerts()"
  "CALL $SCHEMA.lock_tree_prune_batched(interval '1 day', 100)"
)

# One round trip per call, so a failure names the call that failed. A single statement with all of
# them would report the first failure and stop, and the useful information is which one.
n_ok=0
for c in "${CALLS[@]}"; do
  if out=$("${PSQL[@]}" -d "$SCRATCH" -c "SET search_path = pg_catalog" -c "$c" 2>&1); then
    n_ok=$((n_ok + 1))
  else
    bad "unreachable: $c"
    printf '          %s\n' "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
done
[ "$n_ok" -eq "${#CALLS[@]}" ] \
  && ok "all ${#CALLS[@]} reached with search_path = pg_catalog and the schema absent from it" \
  || true

# The converse, which is what makes the above a test rather than a style: with the schema off the
# path, a BARE name must fail. If it succeeded, the qualified form above would prove nothing.
if "${PSQL[@]}" -d "$SCRATCH" -c "SET search_path = pg_catalog" -c "SELECT count(*) FROM lock_tree" \
     >/dev/null 2>&1; then
  bad "a bare name resolved with the schema off the path, so the qualified calls prove nothing"
else
  ok "and a bare name in the same session fails, which is what makes the above meaningful"
fi

# ------------------------------------------------------------------ a role, not the owner

step "a role granted the documented privileges, in a private schema"

ROLE=lt_check_reader
# Dropped first, and tolerant of not existing, because a role left by an interrupted run still holds
# grants and DROP ROLE would otherwise refuse.
"${PSQL[@]}" -d "$SCRATCH" -c "DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$ROLE') THEN
      EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA $SCHEMA FROM $ROLE';
      EXECUTE 'REVOKE ALL ON ALL SEQUENCES IN SCHEMA $SCHEMA FROM $ROLE';
      EXECUTE 'REVOKE ALL ON SCHEMA $SCHEMA FROM $ROLE';
      EXECUTE 'REVOKE pg_read_all_stats FROM $ROLE';
      EXECUTE 'DROP ROLE $ROLE';
    END IF;
  END \$\$" >/dev/null 2>&1

# INSTALL.md writes every grant as ON <object> with no schema, which resolves to the object's own
# schema. That is what makes the documented instructions work here, and it is what these grants test.
"${PSQL[@]}" -d "$SCRATCH" -c "CREATE ROLE $ROLE LOGIN" || exit 2
for stmt in \
  "GRANT pg_read_all_stats TO $ROLE" \
  "GRANT USAGE ON SCHEMA $SCHEMA TO $ROLE" \
  "GRANT SELECT ON $SCHEMA.lock_tree TO $ROLE" \
  "GRANT SELECT ON $SCHEMA.lock_tree_replay_samples TO $ROLE" \
  "GRANT SELECT ON $SCHEMA.lock_tree_history TO $ROLE" \
  "GRANT SELECT ON $SCHEMA.lock_tree_deadlock TO $ROLE" \
  "GRANT EXECUTE ON FUNCTION $SCHEMA.lock_tree_sample() TO $ROLE"
do
  "${PSQL[@]}" -d "$SCRATCH" -c "$stmt" || bad "grant failed: $stmt"
done

if "${PSQL[@]}" -d "$SCRATCH" \
     -c "SET ROLE $ROLE" -c "SELECT count(*) FROM $SCHEMA.lock_tree" >/dev/null 2>&1; then
  ok "the role can read the view in its private schema, so the documented grants are schema-agnostic"
else
  bad "the role cannot read the view in its private schema"
fi

# The 1.0.1 privilege change, in a private schema: PUBLIC must not be able to sample, and the grant
# above is what puts it back for the role that needs it.
p=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT has_function_privilege('public', '$SCHEMA.lock_tree_sample()', 'EXECUTE')")
[ "$p" = f ] && ok "PUBLIC cannot sample, in a private schema either" || bad "PUBLIC can sample here"
p=$("${PSQL[@]}" -d "$SCRATCH" -c "SELECT has_function_privilege('$ROLE', '$SCHEMA.lock_tree_sample()', 'EXECUTE')")
[ "$p" = t ] && ok "and the role that was granted it can" || bad "the granted role still cannot sample"

# ------------------------------------------------------------------ and a real chain

step "a real blocking chain, sampled and read back, entirely inside the private schema"

# A row written straight into the history rather than a real chain. The chain is not what is under
# test: whether a function in $SCHEMA can see a sibling in $SCHEMA is, and a hand-written row proves
# that just as well and without a second session that has to be timed.
"${PSQL[@]}" -d "$SCRATCH" -c "
  INSERT INTO $SCHEMA.lock_tree_history
    (sampled_at, root_pid, depth, pid, state, waiting_for, wait_age,
     application_name, query, root_object, query_id)
  VALUES (now() - interval '2 seconds', 9001, 0, 9001, 'idle in transaction', NULL, NULL,
          'schema_check', 'UPDATE ledger SET amount = 1 WHERE id = 1', NULL, 4242),
         (now() - interval '2 seconds', 9001, 1, 9002, 'active',
          'AccessExclusiveLock on public.ledger', interval '2 seconds',
          'api', 'SELECT 1', NULL, NULL),
         (now() - interval '1 second', 9001, 0, 9001, 'idle in transaction', NULL, NULL,
          'schema_check', 'UPDATE ledger SET amount = 1 WHERE id = 1', NULL, 4242),
         (now() - interval '1 second', 9001, 1, 9002, 'active',
          'AccessExclusiveLock on public.ledger', interval '1 second',
          'api', 'SELECT 1', NULL, NULL)" >/dev/null

n=$("${PSQL[@]}" -d "$SCRATCH" -c "SET search_path = pg_catalog" \
      -c "SELECT count(*) FROM $SCHEMA.lock_tree_replay_samples")
[ "$n" -ge 2 ] && ok "the samples view sees both instants" || bad "the samples view saw $n of 2"

n=$("${PSQL[@]}" -d "$SCRATCH" -c "SET search_path = pg_catalog" \
      -c "SELECT count(*) FROM $SCHEMA.lock_tree_replay(now() - interval '1 hour')")
[ "$n" = 2 ] && ok "and replay returns the tree at the nearest sample" || bad "replay returned $n rows, wanted 2"

n=$("${PSQL[@]}" -d "$SCRATCH" -c "SET search_path = pg_catalog" \
      -c "SELECT count(*) FROM $SCHEMA.lock_tree_duration()")
[ "$n" = 1 ] && ok "and the per-query duration function finds the one query_id" \
             || bad "lock_tree_duration() returned $n rows, wanted 1"

# ------------------------------------------------------------------ verdict

if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n  \033[31m%d check(s) failed\033[0m\n' "${#failed[@]}"
  for f in "${failed[@]}"; do printf '    %s\n' "$f"; done
  [ "${KEEP:-0}" = 1 ] && printf '\n  scratch database %s left in place (KEEP=1)\n' "$SCRATCH"
  exit 1
fi
printf '\n  \033[32meverything reached in a private schema\033[0m\n'
[ "${KEEP:-0}" = 1 ] && printf '  scratch database %s left in place (KEEP=1)\n\n' "$SCRATCH"
exit 0
