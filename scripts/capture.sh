#!/usr/bin/env bash
# scripts/capture.sh: write the documentation examples that are generated rather than written.
#
# The examples in this repository fall into two kinds, and only one of them can be checked:
#
#   generated     printed by running the code, captured here, and compared against what the
#                 documentation says. If a function changes its output the documentation fails.
#   illustrative  written by hand to be readable. These are marked as such in the documentation,
#                 because they are not captures and pretending otherwise is how they rot.
#
# A generated block is delimited in the documentation by:
#
#   <!-- generated: <file>#<block> -->
#   ```
#   ...captured text...
#   ```
#   <!-- /generated -->
#
# and lint-docs.sh compares the block against <file>#<block> after masking. Adding a marker with no
# counterpart, or a block nobody references, is a failure in both directions.
#
# Masking covers what genuinely varies between runs on the same code: pids, timings, and the
# identifiers that follow from them. It deliberately does not cover numbers a reader would check,
# such as the coverage counts in scenarios/README.md, because a check that masks the thing under test
# is not a check.
#
# Needs a server with the extension installed. libpq environment variables are honoured, so
# PGHOST/PGPORT/PGUSER/PGDATABASE work as usual.
set -uo pipefail
cd "$(dirname "$0")/.."

DATABASE=${PGDATABASE:-postgres}
EXAMPLES=docs/examples
mkdir -p "$EXAMPLES"

fail=0
say()  { printf '  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

# ---------------------------------------------------------------- masking
#
# mask() reads text on stdin and writes text with the volatile parts replaced by a stable token.
# Every substitution has a named replacement, so a diff shows what was hidden rather than that
# something was.
# The expressions are in an array rather than one sed invocation with backslash continuations, because
# a comment between two continued lines is swallowed by the continuation and the sed script turns into
# prose. That produced "sed: no -e expression" and an empty demo.out on the first run.
#
# The order matters: pids before ages, so a pid is not first replaced by an age token.
MASKS=(
  # A pid standing at the start of a line or straight after a tree glyph. lock_tree_text puts it there.
  's/^([[:space:]]*)([0-9]{3,})([[:space:]])/\1<PID>\3/'
  's/([[:space:]])([0-9]{3,})([[:space:]])/\1<PID>\3/g'
  # A pid straight after a box-drawing glyph. The character classes above do not match, because the
  # glyph is not whitespace, and the tree output is mostly made of those glyphs.
  's/([└├─│])[0-9]{3,}/\1<PID>/g'
  # A pid inside brackets, which is where lock_tree_command() puts it.
  's/\(([0-9]{2,})\)/(<PID>)/g'
  # An array of pids, which is how the aggregates report the sessions behind a root: {391}. Only
  # digits, commas and spaces inside the braces, so {nightly_batch} and {900} are left alone.
  's/\{[0-9][0-9, ]*\}/{<PIDS>}/g'
  's/\bpid [0-9]{2,}\b/pid <PID>/g'
  's/root_pid \| [0-9]+/root_pid | <PID>/g'
  # A wait or an age: 0s, 12s, 3.5s, 1m30s, 2h, and the 00:00:00 form the aggregates use. The
  # compound forms were missed first time round and left three volatile lines in demo.out.
  's/\b[0-9]+(\.[0-9]+)?(ms|h|m[0-9]+(\.[0-9]+)?s|s)\b/<AGE>/g'
  's/\b00:0[0-9]:[0-9]{2}\b/<AGE>/g'
  's/\b0:00:[0-9]{2}\b/<AGE>/g'
  # Wall-clock timestamps.
  's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/<TIMESTAMP>/g'
  's/[0-9]{2}:[0-9]{2}:[0-9]{2} UTC/<TIMESTAMP>/g'
)

mask() {
  local e
  local -a args=()
  for e in "${MASKS[@]}"; do args+=(-e "$e"); done
  sed -E "${args[@]}"
}

# ---------------------------------------------------------------- the scenarios coverage table
#
# This is the one block in the documentation that is a transcription of a measurement rather than an
# illustration, so it is the one that must not be hand-maintained. run.sh already derives the numbers
# from scenarios/out/*.txt; here they become a markdown table in the shape the documentation uses.
#
# The `?` case matters: a scenario whose coverage block did not print leaves a question mark, and the
# table must show that rather than a zero. A missing measurement and a measurement of zero are
# different facts and the table has to be able to say so.
# The titles are the short names the documentation table already uses, kept here rather than derived
# from the scenario files so that renaming a scenario file does not silently rewrite the prose.
declare -A SHORT=(
  [s1_nightly_batch]='1 nightly batch'
  [s2_three_chains]='2 three chains'
  [s3_row_locks]='3 row locks'
  [s4_wide_queue]='4 wide queue'
  [s5_mixed_locks]='5 advisory locks'
  [s6_deadlock]='6 deadlock'
  [s7_prepared]='7 prepared transaction'
  [s8_many_roots]='8 many roots'
)

ALL="s1_nightly_batch s2_three_chains s3_row_locks s4_wide_queue s5_mixed_locks s6_deadlock s7_prepared s8_many_roots"

if [ ! -d scenarios/out ] || [ -z "$(ls -A scenarios/out 2>/dev/null)" ]; then
    say "capturing the scenarios first"
    ./scenarios/run.sh >/dev/null || { bad "scenarios/run.sh failed"; exit 1; }
fi

{
  echo '# generated by scripts/capture.sh, compared by scripts/lint-docs.sh'
  # The header row is part of the table, not a comment about it. It was a comment first time
  # round, which meant the capture had no header while the documentation did.
  echo '| scenario | waiting | published CTE | pg_lock_tree |'
  echo '|---|---|---|---|'
  for s in $ALL; do
      f="scenarios/out/$s.txt"
      if [ ! -f "$f" ]; then
          printf '| %s | ? | ? | ? |\n' "${SHORT[$s]}"
          continue
      fi
      cov=$(grep -A5 'actually_waiting' "$f" \
            | awk -F'|' '/^\| *[0-9?]/{gsub(/ /,"",$2);gsub(/ /,"",$3);gsub(/ /,"",$4);print $2" "$3" "$4; exit}')
      set -- $cov
      waiting=${1:-?}; std=${2:-?}; tree=${3:-?}
      if [ "$std" != "$tree" ] && [ "$std" != "?" ] && [ "$tree" != "?" ]; then
          std="**$std**"
      fi
      printf '| %s | %s | %s | %s |\n' "${SHORT[$s]}" "$waiting" "$std" "$tree"
  done
} > "$EXAMPLES/scenarios-coverage.md"

rows=$(grep -cE '^\| [0-9]' "$EXAMPLES/scenarios-coverage.md")
unknown=$(grep -c '| ?' "$EXAMPLES/scenarios-coverage.md" || true)
say "wrote $EXAMPLES/scenarios-coverage.md ($rows scenarios, $unknown unknown)"
if [ "$unknown" -gt 0 ]; then
    bad "$unknown scenario(s) reported no coverage numbers; the table says ? rather than 0"
fi

# ---------------------------------------------------------------- the demo transcript
#
# Masked, because every pid and every wait in it moves on every run. It is captured so that a reader
# who runs "make demo" can see what it prints.
#
# THIS FILE IS NOT COMPARED, and it is not byte-stable, for two reasons that have nothing to do with
# the masking:
#
#   - psql right-aligns a numeric column to its widest value, and the mask changes the width of what
#     is in it. A run whose pids are all three digits lays out differently from one where a pid is
#     four, and the trailing spaces move with it.
#   - notices depend on the server's history rather than on the code. A fresh container prints
#     "extension dblink already exists, skipping" where a used one does not.
#
# The two files that ARE compared, demo-sections.md and scenarios-coverage.md, hold section titles and
# coverage counts, neither of which is a pid and neither of which psql aligns. Those are stable, and
# they are the ones the generated-example check depends on.
if psql -X -q -d "$DATABASE" -f demo.sql > /tmp/lock-tree-demo.raw 2>&1; then
    mask < /tmp/lock-tree-demo.raw > "$EXAMPLES/demo.out"
    say "wrote $EXAMPLES/demo.out ($(grep -c '' "$EXAMPLES/demo.out") lines, masked)"
else
    bad "demo.sql failed; see /tmp/lock-tree-demo.raw"
fi
rm -f /tmp/lock-tree-demo.raw

# ---------------------------------------------------------------- the demo's section list
#
# Which sections the demo prints, so the documentation can name them without drifting. This is the
# part of the demo output that is stable and worth checking exactly.
if [ -s "$EXAMPLES/demo.out" ]; then
    grep -E '^# [0-9]+\.' "$EXAMPLES/demo.out" > "$EXAMPLES/demo-sections.md" \
        || bad "demo.out has no numbered sections, so the demo's shape has changed"
    say "wrote $EXAMPLES/demo-sections.md ($(grep -c '' "$EXAMPLES/demo-sections.md") sections)"
fi

[ "$fail" -eq 0 ] && say "capture complete"
exit $fail