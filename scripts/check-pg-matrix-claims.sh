#!/usr/bin/env bash
# check-pg-matrix-claims.sh: a document that states the PostgreSQL range the matrix covers must state
# the range the workflow actually declares.
#
# Why this exists, and why the existing lints do not cover it. README said "Done: ... and the PG 14 to 19
# matrix" while ci.yml ran only 14 and 18 and had done for its whole life. That is a claim about coverage
# that no gate read, and the same class as the six evidence-column claims found in one afternoon. The
# doc-facts lint checks version numbers, scenario counts and links; it does not read the workflow.
#
# What it checks. The versions the CI matrix declares, from either form the repositories in this family
# use:
#
#   pg: ["14", "15", "16", "17", "18"]          bloat and runway
#   - pg_version: "14"                          lock_tree's include list
#
# and then, in every document, a phrase of the form "<n> to <m>" on a line that also says "matrix".
# The two numbers must be the smallest and largest the matrix declares. "19beta4" counts as 19, because
# it is the 19 line even though the string is not a number.
#
# A document that says "the matrix" with no numbers makes no claim and is not checked. A range where the
# endpoints match but the middle is missing (14 to 18 with 15 absent) is NOT caught: a range is what a
# sentence states, and reading every implied member would mean guessing at intent.
#
# Scope on pg_lock_tree, and why it differs from pg_bloat_cause's copy. CHANGELOG.md is NOT read here.
# A changelog entry states the range the matrix covered when that release was cut, and that statement
# stays true after the matrix changes; guarding it would mean rewriting history every time a PostgreSQL
# version leaves the bottom of the matrix, which is a false failure rather than a caught one. This was
# not theoretical: on the first run here the only other guarded claim was the historical line in
# CHANGELOG.md that names `scripts/matrix.sh`, matched on a script name rather than on any claim about
# coverage. The README's own release table said "green on PG 14 to 19beta4" and was NOT guarded, because
# it never used the word "matrix": the one claim a reader relies on was the one the rule skipped. The
# README line was reworded to name the matrix, so that the important claim is the guarded one.

set -eu

die() { echo "  FAIL  $*" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"

ci=".github/workflows/ci.yml"
[ -f "$ci" ] || ci=".github/workflows/test.yml"   # lock_tree names its workflow test.yml
[ -f "$ci" ] || die "no CI workflow found to read the matrix from"

# Every version the matrix declares, from both forms. Sorted numerically on the major, so 19beta4 sorts
# as 19 rather than after 18 by string.
versions=$( { grep -oE '"1[0-9](beta[0-9]+)?"' "$ci" || true; } \
          | tr -d '"' | sed 's/beta.*//' | sort -n -u )
[ -n "$versions" ] || die "no PostgreSQL versions found in $ci; the pattern has stopped matching, which is a failure of this check and not of the repository"

lo=$(printf '%s\n' "$versions" | head -1)
hi=$(printf '%s\n' "$versions" | tail -1)
count=$(printf '%s\n' "$versions" | wc -l | tr -d ' ')
echo "  the matrix declares $count versions: $(printf '%s' "$versions" | tr '\n' ' ')"
echo "  so a stated range must be $lo to $hi"

# Every document that makes a claim about the range the matrix covers today, which is the same set the
# doc-facts lint reads minus CHANGELOG.md. CHANGELOG.md is excluded on purpose: see the header. The
# release notes record what was true at each release, and a rule that failed on them would be asking
# for history to be rewritten rather than for a claim to be corrected.
DOCS="README.md INSTALL.md SECURITY.md CONTRIBUTING.md docs/*.md scenarios/README.md"

bad=""
checked=0
for f in $DOCS; do
    [ -f "$f" ] || continue
    total=$(wc -l < "$f")
    # A WINDOW, not the line. Markdown wraps prose at a column, so the words "the PG matrix" and the
    # range it covers routinely land on different lines, and a same-line rule then checks nothing at
    # all and reports success. That is how the first version of this script passed while checking zero
    # claims. The window is the line and the two either side.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        ln=${hit%%:*}
        text=${hit#*:}
        clause=$(printf '%s\n' "$text" | grep -oE '[0-9]+ to [0-9]+' | head -1)
        [ -n "$clause" ] || continue
        wlo=$((ln - 2)); [ "$wlo" -lt 1 ] && wlo=1
        whi=$((ln + 2)); [ "$whi" -gt "$total" ] && whi=$total
        sed -n "${wlo},${whi}p" "$f" | grep -qiE 'matrix' || continue
        a=$(printf '%s' "$clause" | sed 's/ to .*//')
        b=$(printf '%s' "$clause" | sed 's/.* to //')
        checked=$((checked + 1))
        [ "$a" = "$lo" ] && [ "$b" = "$hi" ] || bad="$bad $f:$ln($a to $b)"
    done < <(grep -nE '[0-9]+ to [0-9]+' "$f" 2>/dev/null || true)
done

if [ -n "$bad" ]; then
    die "these state a PostgreSQL range that the matrix in $ci does not cover, which declares $lo to $hi:$bad"
fi

echo "  $checked range claim(s) checked, 0 wrong"
