#!/usr/bin/env bash
# Do the SQL examples in the documentation still work?
#
# Nothing else in the repository executes them. lint-docs.sh checks that the names inside them exist
# and that their links resolve, but not that the statements parse, plan, or run. That is how
# `SELECT * FROM lock_tree_replay(42)` survived: lock_tree_replay() takes a timestamptz, there has
# never been an integer form of it, and the example had been wrong since 0.14.
#
# Every fenced block tagged sql, or untagged and starting with a query keyword, is split into
# statements and handed to EXPLAIN. EXPLAIN parses and plans without executing, so nothing is
# written and nothing is locked, and the check is safe to run against a live database.
#
# Only queries are planned. GRANT, SET, ALTER, CALL, DROP, COPY and DO are legitimate examples that
# EXPLAIN cannot parse, and a psql meta-command such as \gexec is not SQL at all, so testing those
# proves nothing either way.
#
# EXPECTED_FAILURES lists statements that cannot plan here for a stated reason: an extension the
# documentation itself calls optional and that is not installed. Anything else that fails is a defect
# in the documentation, and adding to that list needs the reason written down beside it.
set -u

cd "$(dirname "$0")/.." || exit 1

: "${PGHOST:=127.0.0.1}"
: "${PGDATABASE:=postgres}"
: "${PGUSER:=postgres}"
export PGHOST PGDATABASE PGUSER

# Each entry is a substring of the error, and why it is tolerated.
EXPECTED_FAILURES=(
    'schema "cron" does not exist|pg_cron is not installed, and INSTALL.md calls it optional'
    'schema "pg_tle" does not exist|pg_tle is not installed, and INSTALL.md calls it optional'
)

if ! psql -X -tAc 'SELECT 1' >/dev/null 2>&1; then
    printf '  cannot reach a database at %s:%s/%s, so the examples cannot be checked\n' \
        "$PGHOST" "${PGPORT:-5432}" "$PGDATABASE"
    exit 1
fi
if ! psql -X -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_lock_tree'" | grep -q 1; then
    printf '  pg_lock_tree is not installed in %s, so the examples cannot be checked\n' "$PGDATABASE"
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

python3 - > "$tmp" <<'PY'
import re, glob, os

SKIP_DOCS = {'CHANGELOG.md'}   # a historical record: it quotes old releases on purpose

def blocks(text):
    out, cur, inside, lang, start = [], [], False, '', 0
    for i, line in enumerate(text.split('\n'), 1):
        m = re.match(r'^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)', line)
        if m:
            if not inside:
                inside, lang, cur, start = True, (m.group(2) or '').lower(), [], i
            else:
                inside = False
                out.append((lang, start, cur))
            continue
        if inside:
            cur.append(line)
    return out

def statements(lines):
    out, buf = [], []
    for l in lines:
        s = l.strip()
        if not s or s.startswith('--'):
            continue
        buf.append(l)
        if s.endswith(';'):
            out.append('\n'.join(buf))
            buf = []
    if buf:
        out.append('\n'.join(buf))
    return out

QUERY = re.compile(r'^\s*(SELECT|WITH|EXPLAIN|TABLE)', re.I)
docdir = 'docs'
for f in sorted(glob.glob('*.md') + glob.glob(os.path.join(docdir, '*.md'))):
    if os.path.basename(f) in SKIP_DOCS:
        continue
    for lang, start, body in blocks(open(f).read()):
        first = next((l for l in body if l.strip() and not l.strip().startswith('--')), '')
        if lang in ('sql', 'psql') or (lang == '' and QUERY.match(first)):
            for i, st in enumerate(statements(body), 1):
                print('%s\t%d\t%d\t%s' % (f, start, i, ' '.join(st.split())))
PY

total=0
checked=0
skipped=0
failed=0
declare -a failures

while IFS=$'\t' read -r file line idx stmt; do
    total=$((total + 1))
    # Placeholders and dollar quoting are prose, not statements to plan.
    #
    # The placeholder test is an ANGLE-BRACKET PAIR, and the reason is worth recording because getting
    # it wrong hid most of what this check exists to test. The first version skipped any statement
    # containing `<` OR `>`, on the theory that placeholders look like <PID>. But named arguments are
    # written `since => interval '7 days'`, so every example using them was skipped, and named
    # arguments are the convention this project's own documentation recommends. A planted
    # lock_tree_incidents_typo went in and the check reported 0 failures. It now looks for the pair.
    case "$stmt" in
        *'...'*|*'<'*'>'*|*'$$'*|*'\\'*)
            skipped=$((skipped + 1)); continue ;;
    esac
    case "$stmt" in
        SELECT*|WITH*|EXPLAIN*|TABLE*|'('SELECT*) ;; *)
            skipped=$((skipped + 1)); continue ;;
    esac
    case "$stmt" in
        *gexec*|*gset*|*gexec*)
            skipped=$((skipped + 1)); continue ;;
    esac

    err=$(psql -X -tA -c "EXPLAIN (COSTS OFF) $stmt" 2>&1 >/dev/null | head -1)
    if [ -z "$err" ]; then
        checked=$((checked + 1))
        continue
    fi

    tolerated=''
    for entry in "${EXPECTED_FAILURES[@]}"; do
        pat=${entry%%|*}
        case "$err" in
            *"$pat"*) tolerated=${entry#*|}; break ;;
        esac
    done
    if [ -n "$tolerated" ]; then
        skipped=$((skipped + 1))
        printf '  known  %s:%s  %s\n' "$file" "$line" "$tolerated"
        continue
    fi
    failed=$((failed + 1))
    failures+=("$file:$line  $(printf '%s' "$err" | cut -c1-110)
    $stmt")
done < "$tmp"

printf '\n  %d example statements: %d plan cleanly, %d not planned, %d failed\n' \
    "$total" "$checked" "$skipped" "$failed"

for f in ${failures+"${failures[@]}"}; do
    printf '  FAIL  %s\n' "$f"
done

[ "$failed" -eq 0 ] || exit 1
exit 0