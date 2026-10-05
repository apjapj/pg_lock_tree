#!/usr/bin/env bash
# scripts/check-upgrade.sh v1.0
# Proves that every supported upgrade path ends in exactly the same objects as a fresh install.
#
# For the default version D and every older version V that has an update path to D:
#   fresh:     CREATE EXTENSION ext;                           (installs D directly)
#   upgraded:  CREATE EXTENSION ext VERSION 'V'; ALTER EXTENSION ext UPDATE;
# then compares a catalog fingerprint of the extension's member objects: function bodies,
# view definitions, table columns (logical order, types, defaults, NOT NULL), constraints,
# indexes, comments, privileges, sequences, and the pg_dump config-table registration.
#
# Usage:  EXT=pg_lock_tree scripts/check-upgrade.sh        (libpq env vars pick the server; needs superuser)
#         FROM="0.1 0.12" EXT=pg_lock_tree scripts/check-upgrade.sh   (only these starting versions)
# Exit 0 = every path matches; 1 = at least one differs (diff printed); 2 = setup problem.
set -euo pipefail

EXT=${EXT:-pg_lock_tree}
PREFIX=${PREFIX:-upgchk}
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -At)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; for d in $("${PSQL[@]}" -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '"'${PREFIX}_%'"'"); do dropdb --if-exists "$d" >/dev/null 2>&1 || true; done' EXIT

FINGERPRINT=$(cat <<'SQL'
WITH ext AS (SELECT oid, extconfig FROM pg_extension WHERE extname = :'ext'),
mem AS (
  SELECT d.classid, d.objid FROM pg_depend d, ext
  WHERE d.refclassid = 'pg_extension'::regclass AND d.refobjid = ext.oid AND d.deptype = 'e'
),
rels AS (SELECT c.oid, c.relkind FROM pg_class c JOIN mem m ON m.classid = 'pg_class'::regclass AND m.objid = c.oid),
lines AS (
  -- functions and procedures (aggregates have no pg_get_functiondef)
  SELECT 'routine ' || p.oid::regprocedure || E'\n' ||
         CASE WHEN p.prokind IN ('f','p','w') THEN pg_get_functiondef(p.oid) ELSE 'aggregate' END AS l
  FROM pg_proc p JOIN mem m ON m.classid = 'pg_proc'::regclass AND m.objid = p.oid
  UNION ALL
  SELECT 'routine-acl ' || p.oid::regprocedure || ' ' || coalesce(p.proacl::text, 'default')
  FROM pg_proc p JOIN mem m ON m.classid = 'pg_proc'::regclass AND m.objid = p.oid
  UNION ALL
  SELECT 'routine-comment ' || p.oid::regprocedure || ' ' || coalesce(obj_description(p.oid, 'pg_proc'), '')
  FROM pg_proc p JOIN mem m ON m.classid = 'pg_proc'::regclass AND m.objid = p.oid
  UNION ALL
  -- relations: kind, privileges, comment, persistence
  SELECT 'relation ' || r.oid::regclass || ' kind=' || r.relkind::text || ' persistence=' || c.relpersistence::text
         || ' acl=' || coalesce(c.relacl::text, 'default')
         || ' comment=' || coalesce(obj_description(r.oid, 'pg_class'), '')
  FROM rels r JOIN pg_class c ON c.oid = r.oid
  UNION ALL
  -- view definitions
  SELECT 'view ' || r.oid::regclass || E'\n' || pg_get_viewdef(r.oid, true)
  FROM rels r WHERE r.relkind IN ('v','m')
  UNION ALL
  -- columns WITHOUT their position, because position is the one thing an upgrade genuinely cannot
  -- reproduce and it is compared on its own below, against a named list. Everything else about a
  -- column (type, NOT NULL, default, identity, comment) is compared strictly, here.
  -- Dropped columns are skipped, so a past DROP COLUMN is not a false alarm.
  SELECT 'column ' || r.oid::regclass || ' ' || a.attname || ' ' ||
         format_type(a.atttypid, a.atttypmod) ||
         CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
         coalesce(' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid), '') ||
         CASE WHEN a.attidentity <> '' THEN ' IDENTITY ' || a.attidentity::text ELSE '' END ||
         coalesce(' COMMENT ' || col_description(r.oid, a.attnum), '')
  FROM rels r
  JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_attrdef ad ON ad.adrelid = r.oid AND ad.adnum = a.attnum
  WHERE r.relkind IN ('r','p','v','m','f')
  UNION ALL
  -- physical position, on its own line so the strict comparison above stays order-independent
  SELECT 'attnum ' || r.oid::regclass || ' ' || a.attname || ' ' || a.attnum::text
  FROM rels r
  JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
  WHERE r.relkind IN ('r','p','v','m','f')
  UNION ALL
  SELECT 'constraint ' || r.oid::regclass || ' ' || con.conname || ' ' || pg_get_constraintdef(con.oid)
  FROM rels r JOIN pg_constraint con ON con.conrelid = r.oid
  UNION ALL
  SELECT 'index ' || pg_get_indexdef(i.indexrelid)
  FROM rels r JOIN pg_index i ON i.indrelid = r.oid
  UNION ALL
  SELECT 'sequence ' || r.oid::regclass || ' ' || s.seqtypid::regtype || ' inc=' || s.seqincrement
  FROM rels r JOIN pg_sequence s ON s.seqrelid = r.oid
  UNION ALL
  SELECT 'trigger ' || pg_get_triggerdef(t.oid)
  FROM rels r JOIN pg_trigger t ON t.tgrelid = r.oid AND NOT t.tgisinternal
  UNION ALL
  -- types, schemas, event triggers and anything else: at least their existence
  SELECT 'member ' || pg_describe_object(m.classid, m.objid, 0)
  FROM mem m WHERE m.classid NOT IN ('pg_proc'::regclass, 'pg_class'::regclass)
  UNION ALL
  -- which tables pg_dump will dump the data of (pg_extension_config_dump)
  SELECT 'config-dump ' || coalesce((SELECT string_agg(c::regclass::text, ',' ORDER BY c::regclass::text)
                                     FROM ext, unnest(ext.extconfig) AS c), 'none')
)
SELECT l FROM lines ORDER BY l;
SQL
)

fingerprint() {  # $1 = database
  "${PSQL[@]}" -d "$1" -v ext="$EXT" <<<"$FINGERPRINT"
}

# Columns whose PHYSICAL position on an upgraded database cannot be made to match a fresh install.
#
# One root cause and one displaced run. ALTER TABLE ADD COLUMN appends, so root_object, added in 0.8,
# lands at the END of lock_tree_alert and lock_tree_history on any database older than 0.8, and every
# column declared after it in the release file moves up by one to make room. That is why the list is
# longer than the two columns that were actually added late: application_name through notify_count in
# lock_tree_alert, and root_object in lock_tree_history. Columns 0.8 pushed are listed because they
# moved, not because anything was done to them.
#
# Paths from 0.8 onwards report no drift at all, because they already have root_object where the
# release file has it. That is the check on the list working in both directions: the entries are
# observed on the old paths and absent from the new ones, rather than being a blanket exemption.
#
# Everything else matches: the set of columns, their types, defaults, NOT NULL flags and comments are
# all identical. Only the order a bare SELECT * returns them in differs, and neither table is meant to
# be read that way. The interface is the view, which names its columns, and this project's own tests
# never SELECT * off these tables.
#
# Rebuilding lock_tree_history to fix the order is not available: it is the one table here that can
# hold gigabytes, and a rebuild inside an update script needs twice the disk and holds ACCESS EXCLUSIVE
# for as long as the copy runs. That is a worse outcome than a column order nobody relies on.
#
# This list is CHECKED rather than trusted, in both directions. A path that drifts on any column not
# named here fails the run, and so does a run where no path drifts on these, because that means the
# source order changed and this list is now describing a difference that no longer exists.
KNOWN_POSITION_DRIFT="lock_tree_alert.application_name lock_tree_alert.first_seen lock_tree_alert.last_notified lock_tree_alert.max_blocked_at lock_tree_alert.max_depth_at lock_tree_alert.notify_count lock_tree_alert.root_object lock_tree_history.query_id lock_tree_history.root_object"

DEFAULT=$("${PSQL[@]}" -d postgres -c "SELECT default_version FROM pg_available_extensions WHERE name = '$EXT'")
[ -n "$DEFAULT" ] || { echo "extension $EXT is not installed on this server (make install first)"; exit 2; }

if [ -n "${FROM:-}" ]; then
  STARTS=$FROM
else
  STARTS=$("${PSQL[@]}" -d postgres -c "
    SELECT source FROM pg_extension_update_paths('$EXT')
    WHERE target = '$DEFAULT' AND path IS NOT NULL
    ORDER BY string_to_array(source, '.')::int[]")
fi
[ -n "$STARTS" ] || { echo "no update paths to $DEFAULT found for $EXT"; exit 2; }

createdb "${PREFIX}_fresh"
"${PSQL[@]}" -d "${PREFIX}_fresh" -c "CREATE EXTENSION $EXT"
fingerprint "${PREFIX}_fresh" > "$WORK/fresh.txt"
# Two views of the same fingerprint: the strict one, which decides pass or fail, and the position one,
# which is checked against KNOWN_POSITION_DRIFT and cannot fail the run on its own.
strict() { grep -v '^attnum ' "$1"; }
positions() { grep '^attnum ' "$1" | sort; }
echo "fresh install of $EXT $DEFAULT: $(grep -c '' "$WORK/fresh.txt") fingerprint lines"

# Which columns sit at a different physical position here than on a fresh install.
# The join key is table AND column, as one field. The first version joined on the table name alone,
# which cross-joins every column of a table against every other column of it: it reported sixteen
# columns as drifted, among them lock_tree.path, which is a view column and cannot drift at all.
drift_of() {
  join -j 1 -o 0,1.2,2.2 \
    <(awk '/^attnum /{print $2 "." $3, $4}' "$1" | sort -k1,1) \
    <(awk '/^attnum /{print $2 "." $3, $4}' "$2" | sort -k1,1) \
  | awk '$2 != $3 {print $1}' | sort -u
}

failed=()
seen_drift=""
for v in $STARTS; do
  db="${PREFIX}_from_${v//[^0-9a-zA-Z]/_}"
  createdb "$db"
  if ! "${PSQL[@]}" -d "$db" -c "CREATE EXTENSION $EXT VERSION '$v'" -c "ALTER EXTENSION $EXT UPDATE" 2>"$WORK/err_$v.txt"; then
    echo "FAIL  $v -> $DEFAULT: the update itself errored"; sed 's/^/      /' "$WORK/err_$v.txt"; failed+=("$v"); continue
  fi
  fingerprint "$db" > "$WORK/up_$v.txt"

  drift=$(drift_of "$WORK/fresh.txt" "$WORK/up_$v.txt")
  seen_drift=$(printf '%s\n%s\n' "$seen_drift" "$drift" | sed '/^$/d' | sort -u | tr '\n' ' ')
  unknown=""
  for d in $drift; do
    case " $KNOWN_POSITION_DRIFT " in *" $d "*) ;; *) unknown="$unknown $d" ;; esac
  done

  if diff -u --label "fresh $DEFAULT" --label "from $v" \
        <(strict "$WORK/fresh.txt") <(strict "$WORK/up_$v.txt") > "$WORK/diff_$v.txt"; then
    if [ -n "$unknown" ]; then
      echo "FAIL  $v -> $DEFAULT: column position differs somewhere the project has not accounted for:$unknown"
      echo "        Add it to KNOWN_POSITION_DRIFT with a reason, or fix the drift."
      failed+=("$v")
    elif [ -n "$drift" ]; then
      # $drift is one item per line because drift_of pipes through sort -u. Left as is, the message
      # ran the list over several lines, which reads as several findings rather than one line of
      # detail. $(echo $drift) flattens it, and loses nothing: the items contain no whitespace.
      echo "ok    $v -> $DEFAULT  (position only: $(echo $drift))"
    else
      echo "ok    $v -> $DEFAULT"
    fi
  else
    echo "FAIL  $v -> $DEFAULT differs from a fresh install:"; sed 's/^/      /' "$WORK/diff_$v.txt" | head -60
    failed+=("$v")
  fi
  dropdb "$db"
done

# The classified drift must actually have been observed, or the list is stale. Without this the
# classification would rot into a permanent exemption the moment somebody tidied the CREATE TABLE
# order and nothing would say so.
#
# Only when FROM is unset, i.e. on a full run. A partial run can legitimately include no path that
# predates the drift: FROM="0.12 0.16" exercises only paths from 0.12 onwards, and 0.8 already had
# root_object where the release file has it, so NOTHING drifts and the entry is never observed. The
# check then failed a run that was entirely correct, which is how a check earns being ignored.
if [ -n "${FROM:-}" ]; then
  [ -n "$seen_drift" ] && echo "note  column position drifted on: $(echo $seen_drift)"
  echo "note  the KNOWN_POSITION_DRIFT staleness check is skipped for a FROM= run, since the paths"
  echo "        you chose may include none that predate the drift. Run with FROM unset to check it."
else
  if [ -z "$seen_drift" ]; then
    echo "FAIL  no upgrade path drifted on column position, but KNOWN_POSITION_DRIFT names:"
    echo "        $KNOWN_POSITION_DRIFT"
    echo "      Either the CREATE TABLE order was changed to match, in which case delete the entry and"
    echo "      this becomes a clean run, or the paths are not exercising what they claim to."
    failed+=("known-position-drift-list")
  else
    for k in $KNOWN_POSITION_DRIFT; do
      case " $seen_drift " in
        *" $k "*) ;;
        *) echo "FAIL  KNOWN_POSITION_DRIFT names $k but no path drifted on it; remove the entry"
           failed+=("known-position-drift-list") ;;
      esac
    done
  fi
fi

if [ ${#failed[@]} -gt 0 ]; then echo "upgrade paths that differ: ${failed[*]}"; exit 1; fi
echo "all upgrade paths to $DEFAULT match a fresh install"
