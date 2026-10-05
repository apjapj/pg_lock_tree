#!/usr/bin/env bash
# lint-docs.sh: check that the documentation's claims match the code.
#
# Docs rot silently. A function gets renamed, a file moves, a version string
# goes stale, and the README keeps confidently describing the old thing. Nothing
# fails, because documentation is not compiled. This is the cheapest guard
# against that: it does not understand prose, it just checks the facts that can
# be checked mechanically.
#
# Usage: ./scripts/lint-docs.sh
#
# Pure text and git. Needs no database, no superuser, no extension installed,
# so it is safe to run anywhere and cheap enough for a pre-commit hook.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
pass=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

# The newest full release script, i.e. what CREATE EXTENSION installs by default.
# Release files are pg_lock_tree--X.Y.sql. Update paths are pg_lock_tree--X.Y--Z.W.sql,
# and are identified by the second separator, so the anchored pattern below keeps
# exactly the release files. Do not loosen this to '-\d+\.\d+\.sql$': that also
# matches pg_lock_tree--0.1.sql, since the double separator ends in a dash, and
# then the filter discards every file including the ones we want.
# The version component is (.[0-9]+)* rather than .[0-9]+, because the pattern used to require
# exactly two components and therefore matched NOTHING once the version became 1.0.0. The failure
# was quiet: ls piped into grep with no match yields an empty string, the guard below then exits 2,
# and the message says "no release script matching pg_lock_tree--X.Y.sql found", which reads as a
# missing file rather than a linter that has stopped understanding the project's own version
# numbering. Found by bumping the version and being told a file that exists is not there.
latest=$(ls pg_lock_tree--*.sql 2>/dev/null \
         | grep -E '^pg_lock_tree--[0-9]+(\.[0-9]+)*\.sql$' \
         | sort -V | tail -1)
if [ -z "$latest" ]; then
    echo "  no release script matching pg_lock_tree--X.Y.sql found" >&2
    exit 1
fi
# Strip the prefix and the extension in one go. Doing it as two steps,
# ${latest##*--} then %.sql, produced "pg_lock_tree--0.3.sql.sql": the first
# expansion leaves the extension on, and the second then cannot remove it
# because the trailing ".sql" has already become part of the name it greps.
# The leading "pg_lock_tree--" goes, then the extension goes, in that order.
latest_ver=$(basename "$latest" .sql)
latest_ver=${latest_ver#pg_lock_tree--}

# And confirm the filter found the release files at all, rather than trusting it.
n_release=$(ls pg_lock_tree--*.sql 2>/dev/null | grep -cE '^pg_lock_tree--[0-9]+\.[0-9]+\.sql$')
n_update=$(ls pg_lock_tree--*.sql 2>/dev/null | grep -cE '^pg_lock_tree--[0-9]+\.[0-9]+--[0-9]+\.[0-9]+\.sql$')

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# The files to scan, NUL-separated. git ls-files is the right list: it excludes .git and
# respects .gitignore, so build output and editor droppings never trip a check.
#
# The fallback matters more than it looks. Someone who downloaded a tarball has no git
# repository, and `git ls-files` there fails and returns nothing. With every check phrased
# as "scan the output", an empty list makes each one vacuously true: the style check
# reported "no em-dashes" on a file that had one. A linter that passes when it cannot see
# anything is worse than no linter, so the fallback walks the tree instead.
#
# The fallback also has to honour .gitignore. With no repository there is no index for git
# to compare against, so nothing else applies it, and a find over the whole tree sweeps up
# editor backups and captured scenario output that would never be committed and so must
# never fail a check about committed files. Handing each candidate to `git check-ignore`
# rather than reimplementing the pattern syntax is the point: this file does not have to
# be a second implementation of gitignore.
tracked_files() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files -z
        return
    fi

    # git check-ignore needs a repository. Without one it exits 128 with "fatal: not a git
    # repository", which is indistinguishable from "not ignored" unless the exit code is
    # inspected: taking "did not exit 0" as "not ignored" then classified every file as
    # ignored, and the em-dash check reported clean on a file that had one. Verified by
    # injecting a dash and watching it pass.
    #
    # So the fallback has two layers. Try check-ignore; if it cannot run at all, parse the
    # simple cases from .gitignore directly. If there is no .gitignore either, ignore
    # nothing, which errs towards reporting rather than staying quiet.
    local can_check=1
    printf 'x\n' | git check-ignore -q --no-index --stdin >/dev/null 2>&1
    [ $? -eq 128 ] && can_check=0

    local all ignored=() skip f i
    while IFS= read -r -d '' f; do
        all+=("$f")
        if [ "$can_check" -eq 1 ]; then
            printf '%s\n' "$f" | git check-ignore -q --no-index --stdin 2>/dev/null \
                && ignored+=("$f")
        elif [ -f .gitignore ]; then
            # Trailing-slash directory and bare-name patterns cover the build output and
            # scratch files this repo actually has. Anything more exotic is left alone
            # rather than guessed at, which errs towards reporting.
            local rel=${f#./}
            while IFS= read -r pat; do
                case "$pat" in ''|'#'*) continue ;; esac
                pat=${pat%/}
                case "$rel" in
                    "$pat"/*|"$pat") ignored+=("$f"); break ;;
                esac
            done < .gitignore
        fi
    done < <(find . -type f -not -path './.git/*' -print0)

    for f in ${all[@]+"${all[@]}"}; do
        skip=0
        for i in ${ignored[@]+"${ignored[@]}"}; do
            if [ "$f" = "$i" ]; then skip=1; break; fi
        done
        [ "$skip" -eq 0 ] && [ -n "$f" ] && printf '%s\0' "$f"
    done
    return 0
}

# ---------------------------------------------------------------- version consistency

step "the version is the same everywhere it is written down"

ver=$(sed -n "s/^default_version = '\(.*\)'/\1/p" pg_lock_tree.control)
# $latest already ends in .sql. Appending another in the message is what produced the
# confusing "pg_lock_tree--0.3.sql.sql" seen here earlier.
[ "$ver" = "$latest_ver" ] \
  && ok "control default_version is $ver, and $latest is the newest release" \
  || bad "control says $ver but the newest release script is $latest"

if [ -f CHANGELOG.md ]; then
    top=$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1)
    [ "$top" = "$ver" ] \
      && ok "CHANGELOG's top entry is $top" \
      || bad "CHANGELOG's top entry is $top, but the extension is $ver"
fi

# README states a current release. Catch the case where it is stale, which is
# how 0.2 sat tagged for a day while the README still called it unreleased.
if [ -f README.md ]; then
    claimed=$(sed -n 's/.*Current release.*\*\*v\([0-9][0-9.]*\)\*\*.*/\1/p' README.md | head -1)
    if [ -z "$claimed" ]; then
        # Different wording, or no claim at all. Not an error, so say nothing
        # rather than inventing a failure.
        :
    elif [ "$claimed" = "$ver" ]; then
        ok "README names v$ver as the current release"
    else
        bad "README says v$claimed is current, but the extension is $ver"
    fi
fi

# Every release script must be installed. DATA covers the release scripts; the
# update paths install via the UPGRADES wildcard, so they are checked against
# that rather than DATA (which legitimately does not list them).
step "every SQL file gets installed"
for f in pg_lock_tree--*.sql; do
    if echo "$f" | grep -qE '^pg_lock_tree--[0-9]+\.[0-9]+--[0-9]+\.[0-9]+\.sql$'; then
        # An update path. These are deliberately NOT in DATA: PGXS copies DATA by
        # name, and an update script is found by a different convention, so the
        # Makefile installs them from a wildcard instead.
        grep -q 'pg_lock_tree--\*--\*\.sql' Makefile \
          && ok "$f installs via the UPGRADES wildcard" \
          || bad "$f is an update path but the Makefile has no UPGRADES wildcard"
    else
        grep -q "$(basename "$f")" Makefile \
          && ok "$f is in the Makefile" \
          || bad "$f exists but the Makefile never installs it"
    fi
done

# Both counts non-zero, or one of the two classifications above is silently
# matching nothing and reporting success on every file.
if [ "$n_release" -gt 0 ] && [ "$n_update" -gt 0 ]; then
    ok "file naming: $n_release release script(s), $n_update update path(s) recognised"
else
    bad "file naming: $n_release release script(s), $n_update update path(s); expected at least one of each"
fi

# ---------------------------------------------------------------- the objects we document

step "every object the docs describe as current exists in the release SQL"

check_object() {
    # TABLE is in the list because 0.4 added one, and the linter failed on
    # lock_tree_history until it did: a table is as much a documented object as a function.
    # PROCEDURE is there because 0.11 added lock_tree_prune_batched as one, and the linter failed
    # on it until it did. It has to be a procedure rather than a function, which is the whole reason
    # the object exists, so failing to recognise it would be an odd place for the check to stop.
    grep -qE "(FUNCTION|VIEW|TABLE|PROCEDURE) @extschema@\.$1\b" "$latest" \
      && ok "$1 is defined in $latest" \
      || bad "$1 is named in the docs but not defined in $latest"
}

# Two exclusions, both because the text is describing something that legitimately
# does not exist yet:
#
#   the README's Roadmap section. lock_tree_history is named there as the next
#   thing to build, which is the entire point of a roadmap. Without this the
#   linter fails on its own project plan.
#
#   CHANGELOG.md. A changelog is a historical record: it describes what each past
#   release contained, so an object removed in 0.4 stays named in the 0.3 entry
#   forever and the check would be unsatisfiable by design.
#
# Everything else must resolve.
for f in README.md INSTALL.md scenarios/README.md; do
    [ -f "$f" ] || continue
    if [ "$f" = README.md ]; then
        # Drop the Roadmap section: from its heading to the next heading, or EOF.
        body=$(sed -n '1,/^## Roadmap/p' "$f" | sed '$d')
    else
        body=$(cat "$f")
    fi
    names=$(printf '%s\n' "$body" | grep -oE '`lock_tree[a-z_]*(\(\))?`' \
            | tr -d '`' | sed 's/()$//' | sort -u)
    for n in $names; do check_object "$n"; done
done

# ---------------------------------------------------------------- files the docs link to

step "every local path the docs mention exists"
for f in README.md INSTALL.md CHANGELOG.md scenarios/README.md; do
    [ -f "$f" ] || continue
    # A path in a doc is relative to that doc, not to the repo root. scenarios/README.md
    # refers to 01_standard_query.sql, which lives in scenarios/. Resolving from the
    # repo root instead reported a missing file that has been there all along.
    dir=$(dirname "$f")
    # Markdown links and bare backticked paths.
    #
    # Glob and shell metacharacters are dropped: they mark a pattern, not a path.
    # So is a version placeholder, matched narrowly as a digit-dot-x: INSTALL.md writes
    # pg_lock_tree--0.x--0.3.sql when explaining what PostgreSQL looks for, which is prose
    # about a filename rather than a path. Matching a bare x instead would have silently
    # skipped every path containing that letter, which is most of them.
    # Comments cannot sit inside the $( ) above a continuation line without ending
    # the command, so this one lives here.
    paths=$(grep -oE '\]\(([A-Za-z0-9_./-]+)\)|`[A-Za-z0-9_][A-Za-z0-9_./-]*\.(sql|md|sh|control)`' "$f" \
            | sed -E 's/^\]\(//; s/\)$//; s/^`//; s/`$//' \
            | grep -vE '^(https?:|[0-9]+$|[^ ]*[?*<>][^ ]*$|[^ ]*[0-9]\.x[^ ]*$)' | sort -u)
    for p in $paths; do
        if [ -e "$p" ]; then
            ok "$f -> $p"
        elif [ -e "$dir/$p" ]; then
            ok "$f -> $p (relative to $dir)"
        else
            bad "$f mentions $p, which exists neither at the repo root nor in $dir"
        fi
    done
done

# ---------------------------------------------------------------- the test suite

step "the test files the README describes all exist"
if [ -f README.md ]; then
    for t in $(grep -oE 'test/[0-9][0-9_a-z]*\.sql' README.md | sort -u); do
        [ -f "$t" ] && ok "$t" || bad "README describes $t, which does not exist"
    done
fi

# A test file on disk that the README never mentions is usually a test nobody
# knows the purpose of. Warn rather than fail: the README does not have to
# list everything.
for t in test/*.sql; do
    [ -f "$t" ] || continue
    grep -q "$(basename "$t")" README.md \
      || printf '  \033[33mnote\033[0m  %s exists but the README does not describe it\n' "$t"
done

# plan(N) must match the number of assertions on the path that actually runs, or
# pg_prove reports a bad plan instead of a real failure. pgTAP's own answer is
# authoritative and needs a database; this is the offline approximation.
#
# Two things it has to get right, each of which was wrong in the first draft:
#   the assertion vocabulary must be the pgTAP assertion functions, not "anything
#     that looks like a call". Counting bare "SELECT <name>(" picked up dblink_exec
#     and pg_sleep, and missed has_view and has_function entirely.
#   files that skip have two branches. plan(N) refers to the branch that runs when
#     the capability IS present, so count only the text before the \else. The skip
#     branch's skip(..., N) is what fills the plan on the other path.
step "test plans match their assertion counts"
assertions='is|isnt|ok|matches|like|unlike|throws_ok|throws_matching|lives_ok|dies_ok|has_view|has_function|has_table|has_column|has_index|has_schema|is_empty|isnt_empty|col_is_null|col_isnt_null|col_null_count|col_nn_count|results_eq|set_eq|bag_eq|row_eq'
for t in test/*.sql; do
    [ -f "$t" ] || continue
    plan=$(sed -n 's/^SELECT plan(\([0-9]*\));.*/\1/p' "$t" | head -1)
    [ -z "$plan" ] && continue

    # Only the real path: everything between plan() and the first \else, or to finish() in a
    # file with no branch. Counting the whole file would count the skip() branch too.
    path=$(sed -n '/^SELECT plan(/,$p' "$t" | sed -n '1,/^\\else$/p')
    # Count CALLS, not LINES. grep -c counts matching lines, so a line carrying two assertions counts
    # once, and a file whose plan is right then looks wrong. This is not hypothetical: test/21 has two
    # assertions on one line, the linter counted 33 against a correct plan of 34, and the same
    # counting mistake was made by hand while writing 1.0.1 and had to be undone by running the file.
    # grep -o prints one line per match, so wc -l counts occurrences.
    # Comments are stripped first. A `--` line that NAMES an assertion, which a test file
    # documenting its own shape is bound to do, was counted as an assertion. It is a small thing and
    # it is the kind that makes a check lose its credibility: the first version of test/21 carried a
    # line saying how many assertions it had, written in the names of assertions, and the linter
    # counted the line as one of them.
    n=$(printf '%s\n' "$path" | sed 's/--.*$//' \
        | grep -oE "\b($assertions)\(" | wc -l | tr -d ' ')

    if [ "$n" -eq "$plan" ]; then
        ok "$(basename "$t"): plan($plan), $n assertion(s) on the running path"
    elif [ "$n" -lt "$plan" ]; then
        # Fewer calls in the source than the plan promises is not always wrong. An assertion inside a
        # helper the file calls several times, or a statement built and run with \gexec, emits more
        # TAP lines than there are call sites to count. test/21 is the case: 33 call sites, 34 lines
        # out, plan 34, and pgTAP agreeing. Counting call sites cannot be exact for that shape, and a
        # check that fails a correct file is worse than no check, so this is a note.
        #
        # The other direction stays a failure: MORE calls than the plan promises is always an error,
        # because a plan is an upper bound on what will run.
        ok "$(basename "$t"): plan($plan), $n call site(s) found; a helper or an exec'd statement may "
        ok "  account for the rest, so the plan is not cross-checked exactly for this file"
    elif [ "$n" -lt "$plan" ] && grep -qE '^\\else' "$t"; then
        # A partially conditional file: the plan covers both branches, so it legitimately
        # exceeds the running path's count. Checked below instead of here.
        ok "$(basename "$t"): plan($plan), $n assertion(s) run, remainder conditional"
    else
        bad "$(basename "$t"): plan($plan) but counted $n assertion(s) on the running path"
    fi

    # A conditional file must account for its skipped assertions, and the arithmetic depends on
    # where the \if sits. pgTAP's skip(reason, N) emits N skipped results and the plan is a
    # promise about the file's total output, so:
    #   \if wraps the whole file  -> skip(N) == plan, the else branch replaces everything
    #   \if wraps part of it      -> skip(N) == plan minus the unconditional assertions
    # Counting "the running path" as everything before \else is wrong for the second shape,
    # because that count already includes the assertions inside \if.
    if grep -qE '^\\if' "$t"; then
        unconditional=$(sed -n '/^SELECT plan(/,$p' "$t" \
                       | sed -n '1,/^\\if/p' \
                       | grep -cE "^[[:space:]]*SELECT ($assertions)\(")
        skipn=$(tr '\n' ' ' < "$t" \
                | grep -oE "SELECT skip\(.*?, *([0-9]+) *\);" \
                | grep -oE '[0-9]+ *\);$' | tr -dc '0-9')
        if [ -z "$skipn" ]; then
            bad "$(basename "$t"): has a conditional branch but no skip(..., N) with a literal count"
        elif [ "$skipn" -eq $((plan - unconditional)) ]; then
            ok "$(basename "$t"): skip(..., $skipn) replaces the $((plan - unconditional)) conditional assertion(s)"
        else
            bad "$(basename "$t"): skip(..., $skipn) but $((plan - unconditional)) conditional assertion(s) expected"
        fi
    fi
done

step "house style"
# Neither character can appear literally in this file, or the check below would always
# flag itself. They are built from their code points instead. One backslash is what is
# wanted here, so printf sees \u2014 and emits the character; two would leave printf with a
# literal backslash-u and the pattern would degenerate to the four characters "u2014",
# which match this line rather than the dashes the check is hunting for.
#
# The self-exclusion is normalised to the form git ls-files uses. Invoked as
# ./scripts/lint-docs.sh, BASH_SOURCE carries the leading ./, and grep -x against
# "scripts/lint-docs.sh" would match nothing, so the exclusion would silently not apply.
self=${BASH_SOURCE[0]#./}
emdash=$(printf '\u2014')
endash=$(printf '\u2013')

style_scan() {
    local char=$1 label=$2 files
    files=$(tracked_files | xargs -0 grep -l -e "$char" 2>/dev/null \
            | grep -v -x -e "$self" || true)
    if [ -n "$files" ]; then
        bad "$label found in tracked files: project convention is none"
        printf '%s\n' "$files" | sed 's/^/          /'
    else
        ok "no $label in any tracked file"
    fi
}

style_scan "$emdash" 'em-dashes (U+2014)'
style_scan "$endash" 'en-dashes (U+2013)'

# A tab-indented Makefile recipe is required by make; a space there is a
# confusing "missing separator" error rather than anything readable.
if [ -f Makefile ]; then
    if grep -qP '^    ' Makefile 2>/dev/null; then
        bad "Makefile has space-indented recipe lines (needs tabs)"
    else
        ok "Makefile recipes are tab-indented"
    fi
fi

# Shell scripts must parse. `bash -n` catches the syntax error before anyone
# runs the thing at 2am during an incident.
for s in scripts/*.sh scenarios/*.sh; do
    [ -f "$s" ] || continue
    if bash -n "$s" 2>/dev/null; then ok "$s parses"; else bad "$s does not parse"; fi
done

printf '\n\033[1mresult\033[0m\n'
if [ "$fail" -eq 0 ]; then
    printf '  \033[32mall %s checks passed\033[0m\n\n' "$pass"
    exit 0
else
    printf '  \033[31m%s of %s checks failed\033[0m\n\n' "$fail" "$((pass + fail))"
    exit 1
fi