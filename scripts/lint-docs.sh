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

# Every documentation file. Defined once, because it was written out in three places and the split
# updated one of them: a name in backticks in a file the other two missed was never checked.
#
# CHANGELOG.md is here for objects and paths but its objects are deliberately not required to resolve:
# see check_object. docs/roadmap.md and docs/design-notes.md are here for the same reason as the rest.
DOCS_ALL="README.md INSTALL.md CONTRIBUTING.md CHANGELOG.md scenarios/README.md docs/*.md"

fail=0
pass=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

# No check in this file pipes into grep -q; every one takes its input as a here-string. Under the
# pipefail set above, grep -q exiting on its first match closes the pipe, the producer takes SIGPIPE,
# and the pipeline reports "not found" for a match it found, once the input is over the 64 KiB pipe
# buffer. Found in the Objects-row check added after 1.1.10, which reported real rows missing at
# random. Twelve older sites had the same shape and none could fire on today's inputs: the largest
# is a 1,473-byte fenced block in INSTALL.md. They were changed anyway, so nobody has to work out which
# are safe.

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
n_release=$(ls pg_lock_tree--*.sql 2>/dev/null | grep -cE '^pg_lock_tree--[0-9]+(\.[0-9]+)*\.sql$')
n_update=$(ls pg_lock_tree--*.sql 2>/dev/null | grep -cE '^pg_lock_tree--[0-9]+(\.[0-9]+)*--[0-9]+(\.[0-9]+)*\.sql$')

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
    if grep -qE '^pg_lock_tree--[0-9]+(\.[0-9]+)*--[0-9]+(\.[0-9]+)*\.sql$' <<<"$f"; then
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

  # No file may appear twice in DATA. GNU install refuses to install the same file twice in one
  # command and stops, so a duplicate is not a warning, it is a broken `make install` for everyone
  # following INSTALL.md.
  #
  # This existed as a defect rather than as a missing check: 1.1.11 listed
  # pg_lock_tree--1.1.10--1.1.11.sql in DATA twice, because the same edit was applied to the line
  # twice, and every check above still passed. Each of them asks whether a file is PRESENT and none
  # asks whether it appears more than once. Found by running `make install` in six containers, which
  # is the first thing a stranger does and the one thing nothing here was doing.
  data_line=$(sed -n 's/^DATA[[:space:]]*=[[:space:]]*//p' Makefile | head -1)
  dup_data=$(printf '%s\n' "$data_line" | tr ' ' '\n' | grep -v '^$' | sort | uniq -d)
  if [ -z "$dup_data" ]; then
      ok "no file is listed twice in DATA, which install would refuse"
  else
      bad "DATA lists these more than once and install stops: $(printf '%s' "$dup_data" | tr '\n' ' ')"
  fi

  # The reverse: a name in DATA with no file behind it, which PGXS fails on just as hard.
  missing_data=$(printf '%s\n' "$data_line" | tr ' ' '\n' | grep -v '^$' | while read -r f; do
                     [ -f "$f" ] || printf '%s ' "$f"
                 done)
  if [ -z "$missing_data" ]; then
      ok "every name in DATA has a file on disk behind it"
  else
      bad "DATA lists files that do not exist: $missing_data"
  fi


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
        # INDEX joined them in 1.1.0, and for the same kind of reason. The extension ships four
        # indexes and the documentation now discusses one of them by name, in prose, in backticks.
        # With no INDEX alternative a backticked lock_tree_history_application_idx was reported as an
        # object that does not exist, which is the opposite of what the check is for. Verified both
        # ways: a planted name matching no index fails, and the real one passes.
        # ways, and the second attempt found that an index name has to match in EITHER order.
        # CREATE INDEX puts the index name before the schema and qualifies the table instead, so
        # "INDEX @extschema@.name" only matches where a COMMENT ON INDEX or DROP INDEX happens to
        # say it. lock_tree_history_application_idx passed on its comment and
        # lock_tree_history_pid_idx failed for want of one, so the check reported a real index as
        # missing. All four indexes are now checked, and a planted name that matches none fails.
    grep -qE "(FUNCTION|VIEW|TABLE|PROCEDURE|INDEX) @extschema@\.$1\b|CREATE INDEX $1\b" "$latest" \
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
# Every documentation file, read whole.
#
# This glob listed three files while the split moved the material into nine, so seven of them were not
# scanned at all: a name in backticks in docs/incident.md that matches no object in the release passed.
# Found by planting one. The Roadmap exclusion is gone with it: there is no Roadmap section in the
# README any more, so `sed -n '1,/^## Roadmap/p'` ran to end of file and the whole file was read
# anyway, which is what a partial read of a documentation file should never do.
for f in $DOCS_ALL; do
    [ -f "$f" ] || continue
    # Two extractions, because prose and code drift apart. A name in backticks in prose is
    # checkable; the same name inside a ```sql block was invisible, so
    # `SELECT * FROM lock_tree_no_such_thing();` in an example passed. Found by planting exactly that.
    #
    # check_object resolves functions, procedures, views and tables alike, so pulling bare
    # lock_tree_ names out of fenced blocks cannot produce a false failure for a setting such as
    # lock_tree.history_query: that reduces to `lock_tree`, which is the view.
    names=$(
        {
            grep -oE '`lock_tree[a-z_]*(\(\))?`' "$f" | tr -d '`' | sed 's/()$//'
            awk '
                /^```/          { inside = !inside; next }
                inside          { print }
            ' "$f" | grep -oE 'lock_tree_[a-z_]+' 
        } | sort -u
    )
      # The CHANGELOG exclusion, which the comment above this loop described for a long time and no
      # code implemented. It is correct on the merits rather than merely convenient: a changelog is a
      # historical record, so it names objects that a later release removed, and requiring those to
      # resolve makes the check unsatisfiable by design. It came up for real writing the 1.1.1 entry,
      # which quotes a function name that does not exist because that is the example being discussed.
      #
      # PATHS are not exempted. A path in the changelog should still resolve, and one did not: see
      # the 1.1.1 entry, which named a file in a directory it is not in.
      case "$f" in
          CHANGELOG.md) continue ;;
      esac
      for n in $names; do check_object "$n"; done
done

# ---------------------------------------------------------------- files the docs link to

step "every local path the docs mention exists"
for f in $DOCS_ALL; do
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
    # A markdown link is extracted as its target, and a bare backticked name is extracted from the text
    # with the links blanked out first. The label is not a path: [`lint-docs.sh`](../scripts/lint-docs.sh)
    # carries a bare filename in the label, which resolves neither from the repo root nor from the
    # linking document, and it was reported as a missing file that has been there all along.
    #
    # A lookbehind was the first attempt and it was on the wrong side of the label: the label comes
    # before `](`, not after, so there was nothing to look behind. Blanking the links is plainer and
    # needs no PCRE.
      # '#' is IN the class, and until 1.1.1 it was not. So [Backups and restores]
      # (INSTALL.md#backups-and-restores), the link that was reported broken, never matched this
      # pattern at all and was never checked: every link carrying an anchor had been invisible. The
      # fragment is split off below and the file part is tested on its own.
      link_targets=$(grep -oE '\]\([A-Za-z0-9_./#-]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
    without_links=$(sed -E 's/\[[^][]*\]\([^)]*\)/@LINK@/g' "$f")
    bare_names=$(printf '%s\n' "$without_links" \
                 | grep -oE '`[A-Za-z0-9_][A-Za-z0-9_./-]*\.(sql|md|sh|control)`' | tr -d '`')
      # A fragment is tested against the headings of the file it points at, because a link to a file
      # that exists but a heading that does not renders fine and scrolls nowhere. Anchor targets are
      # GitHub-style slugs of the heading text: lower case, spaces to hyphens, punctuation dropped.
      for p in $link_targets; do
          case "$p" in
              *'#'*) ;;
              *) continue ;;
          esac
          frag=${p##*#}
          file=${p%%#*}
          [ -n "$file" ] && tgt="$dir/$file" || tgt="$f"
          [ -e "$tgt" ] || continue
          if awk -v want="$frag" '
              function slug(line,   s) {
                  s = tolower(line)
                  gsub(/[^a-z0-9 -]/, "", s)
                  gsub(/ /, "-", s)
                  return s
              }
              /^#+[[:space:]]/ {
                  h = $0
                  sub(/^#+[[:space:]]*/, "", h)
                  if (slug(h) == want) { found = 1 }
              }
              END { exit(found ? 0 : 1) }' "$tgt"; then
              ok "$f -> $p (anchor exists)"
          else
              bad "$f links to $p, and $tgt has no heading that slugifies to that anchor"
          fi
      done
    paths=$(printf '%s\n%s\n' "$link_targets" "$bare_names" \
            | grep -vE '^(https?:|[0-9]+$|[^ ]*[?*<>][^ ]*$|[^ ]*[0-9]\.x[^ ]*$)' | sort -u)
      # Two categories, and they are not the same kind of thing, so they get different rules.
      #
      #   link_targets  a real markdown link, [label](target). A renderer resolves it relative to the
      #                 containing file and nowhere else. Getting that wrong is invisible to grep and
      #                 obvious in a browser: docs/reference.md linked to INSTALL.md, which passes
      #                 every existence test because INSTALL.md exists at the repo root, and then 404s
      #                 in Forgejo. Seven links did that, two of them added by 1.1.0. Found by opening
      #                 the rendered page rather than by running this script.
      #
      #                 The earlier version of this check tested the repo root FIRST, which is what
      #                 let all seven through.
      #
      #   bare_names    a backticked path in prose, `test/06_cron.sql`. Not a link at all: it renders
      #                 as code. It only has to exist somewhere, and the repo root is the sensible
      #                 place to look. Applying the renderer's rule to these reported 24 false
      #                 failures the first time, which is why the two are separated rather than merged.
      for p in $paths; do
          # The fragment is not part of the filename. INSTALL.md#grants is INSTALL.md; testing it as
          # written reported 48 links missing that all exist.
          t=${p%%#*}
          [ -z "$t" ] && continue
          # Membership is an exact whole-line match, not a substring test. `case " $link_targets " in
          # *" $p "*)` was the first attempt and it never matched anything, because link_targets is
          # newline separated: the characters around a target are newlines, not the spaces the pattern
          # asks for. Every link therefore fell through to the bare-name branch and the two rules
          # collapsed into one, which is the bug this whole change set was about.
          if grep -qxF -- "$p" <<<"$link_targets"; then
              if [ "$dir" = "." ]; then
                      if [ -e "$t" ]; then
                          ok "$f -> $t"
                      else
                          bad "$f links to $t, which does not exist at the repo root"
                      fi
                  elif [ -e "$dir/$t" ]; then
                      ok "$f -> $t (relative to $dir)"
                  elif [ -e "$t" ]; then
                      bad "$f links to $t, which exists at the repo root but not beside the document, \
so a renderer will not find it"
                  else
                      bad "$f links to $t, which exists neither beside the document nor at the repo root"
              fi
          else
              if [ -e "$t" ] || [ -e "$dir/$t" ]; then
                  ok "$f names $t"
              else
                  bad "$f names $t, which exists neither at the repo root nor in $dir"
              fi
          fi
      done
done

# ---------------------------------------------------------------- link syntax inside code fences

step "no markdown link syntax inside a fenced shell block, where it is neither a link nor shell"

# [scripts/check-alert.sh](scripts/check-alert.sh) inside a bash block is not a link: a fence renders
# as code, so nothing is clickable. It is also not runnable, because [ is the test command and the
# shell would try to run x](x). Nine lines of the documentation were like this, including commands a
# reader would reasonably copy and paste.
#
# Restricted to shell-ish fence languages. Inside an md block, showing link syntax is the whole point,
# and a general check would fail it. An UNTAGGED fence is not checked either, because the language is
# genuinely unknown: one transcript here was untagged and had to be tagged console before the check
# could see it. Recorded rather than hidden.
fence_tmp=$(mktemp)
for f in $DOCS_ALL; do
    [ -f "$f" ] || continue
    : > "$fence_tmp"
    awk -v out="$fence_tmp" '
        /^[[:space:]]*(```|~~~)/ {
            if (inside) { inside = 0; lang = "" }
            else {
                inside = 1
                t = $0
                sub(/^[[:space:]]*`+/, "", t); sub(/~~~.*$/, "", t)
                gsub(/[[:space:]]/, "", t)
                lang = tolower(t)
            }
            next
        }
        inside {
            if (lang ~ /^(bash|sh|shell|zsh|console)$/ && index($0, "](") > 0) {
                printf "%s:%d: %s\n", FILENAME, FNR, $0 >> out
            }
        }
    ' "$f"
    if [ -s "$fence_tmp" ]; then
        while IFS= read -r line; do
            bad "link syntax inside a shell fence, which is neither a link nor runnable: $line"
        done < "$fence_tmp"
    else
        ok "$f has no markdown link syntax inside a shell fence"
    fi
done
rm -f "$fence_tmp"

# ---------------------------------------------------------------- the test suite

step "the test files the README describes all exist"
# The test table lives in CONTRIBUTING.md, where the make targets it sits next to are.
TESTDOC=CONTRIBUTING.md
if [ -f "$TESTDOC" ]; then
    for t in $(grep -oE 'test/[0-9][0-9_a-z]*\.sql' "$TESTDOC" | sort -u); do
        [ -f "$t" ] && ok "$t" || bad "$TESTDOC describes $t, which does not exist"
    done
fi

  # The other direction, and it is a FAILURE where it used to be a note. The README has a table of
  # what each test file covers, so a file missing from it is a test whose purpose nobody can find, and
  # a note is exactly the wrong severity for that. The review of 0.14 found files 16 to 18 absent from
  # the table while this note printed on every run of the script, every day, to nobody. A check that
  # reports a real problem at a severity that gets ignored is worse than no check, because it teaches
  # the reader that the output is not worth reading.
  unlisted=0
  for t in test/*.sql; do
      [ -f "$t" ] || continue
      if ! grep -q "$(basename "$t")" "$TESTDOC"; then
          bad "$t exists but the test table in $TESTDOC does not describe it"
          unlisted=$((unlisted + 1))
      fi
  done
  [ "$unlisted" -eq 0 ] && ok "every test file on disk is in the $TESTDOC test table"

  # The same drift one level up: a function in the release that the Objects table does not mention. A
  # function added and not documented is invisible in review, and the review of 0.14 asked for this.
  rel=$(ls pg_lock_tree--*.sql 2>/dev/null | grep -E '^pg_lock_tree--[0-9]+(\.[0-9]+)*\.sql$' | sort -V | tail -1)
  REFDOC=docs/reference.md
  if [ -n "$rel" ] && [ -f "$REFDOC" ]; then
      undocumented=0
      for f in $(grep -oE '^CREATE (OR REPLACE )?FUNCTION @extschema@\.lock_tree_[a-z_]+' "$rel" \
                   | sed 's/.*\.//' | sort -u); do
          if ! grep -qE "(^|[^a-z_])${f}([^a-z_]|$)" "$REFDOC"; then
              bad "$f() is in $rel but not the Objects table in $REFDOC"
              undocumented=$((undocumented + 1))
          fi
      done
      [ "$undocumented" -eq 0 ] \
        && ok "every function in $rel appears in the Objects table in $REFDOC" \
        || bad "$undocumented function(s) in $rel are not in the Objects table in $REFDOC"
  fi

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

# ---------------------------------------------------------------- links and anchors
#
# Every relative link and every #anchor, across the docs and the changelog, has to resolve. The split
# is what makes this worth having: sections moved between files, so a link that used to be
# `README.md#some-heading` now points at a heading that lives in docs/incident.md, and nothing in a
# plain text diff shows that an anchor no longer exists. The CHANGELOG had been linking to README
# anchors for several releases before this check existed.
step "every link and anchor in the docs resolves"

# GitHub's anchor rule: lowercase, drop anything that is not a letter, digit, space or hyphen, then
# spaces become hyphens. Implemented with sed rather than assumed, because an approximation of the
# rule produces failures on headings that are perfectly fine.
anchor_of() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9 -]//g' -e 's/ /-/g'
}

# Every heading in a file, as anchors. A setext underline (=== or ---) under a line of text is a
# heading too, and the README uses one for the title.
anchors_in() {
  [ -f "$1" ] || return 0
  awk '
    /^#+ /       { sub(/^#+ /, ""); print tolower($0) }
    /^[^=-]+$/   { if (getline nxt) { if (nxt ~ /^=+$/) { print tolower($0) } ; next } }
  ' "$1" 2>/dev/null | sed -e 's/[^a-z0-9 -]//g' -e 's/ /-/g' | sort -u
}

# Build the anchor set for every doc, as file=anchor lines, then check each link against it.
all_anchors=$(mktemp)
trap 'rm -f "$all_anchors"' RETURN 2>/dev/null || true
for f in $DOCS_ALL; do
  [ -f "$f" ] || continue
  canon="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  anchors_in "$f" | while read -r a; do printf '%s\t%s\n' "$canon" "$a"; done >> "$all_anchors"
done

broken=0
unphony=0
for f in $DOCS_ALL; do
  [ -f "$f" ] || continue
  dir=$(dirname "$f")
  # Markdown links: [text](target). The fragment is optional. Requiring a '#' here, which is what
  # this did first, silently skipped every anchorless link, so a link to a file that does not exist
  # passed as long as nobody had added a fragment to it. Found by planting exactly that.
  for target in $(grep -oE '\]\([^)]*\)' "$f" | sed -e 's/^](//' -e 's/)$//' \
                  | grep -vE '^(https?:|mailto:)' | grep -v '^$' \
                  | sed 's:/*$::' | sort -u); do
      # Split on the '#' only if there is one. ${target#*#} on a target with no '#' returns the
      # target unchanged, which made an anchorless link look like a fragment of the whole path and
      # reported every relative link in the repo as an unresolvable anchor.
      path=${target%%#*}
      case "$target" in
        *#*) frag=${target#*#} ;;
        *)   frag="" ;;
      esac
      # Only a target that STARTS with '#' is a same-file anchor. Testing $path = $target instead,
      # as this did, is true for every link with no fragment, so [x](does-not-exist.md) had its path
      # rewritten to the linking file, which exists, and passed. Found by planting that link.
      case "$target" in
        \#*) path="$f" ;;
      esac
      # A same-file anchor has an empty $path, so $resolved has to start from the linking file.
      resolved=$path
      [ -n "$path" ] || resolved="$f"
      [ -e "$resolved" ] || resolved="$dir/$path"
      # Normalise, or the anchor lookup compares a path with a .. in it against an anchor set keyed
      # on the canonical name and reports a heading that is plainly there. docs/../INSTALL.md is
      # INSTALL.md, and the check said it had no #backups-and-restores heading, which it has.
      # dirname first: realpath on a bare file name resolves against the CWD, not the doc.
      if [ -e "$resolved" ]; then
          resolved=$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")
      fi
      # -e, not -f: a link to a directory is legitimate. [scenarios/](scenarios/) is one, and the
      # trailing slash was stripped when the targets were collected so that this lookup finds it.
      if [ ! -e "$resolved" ]; then
          bad "$f links to $target, and $path does not exist"
          broken=$((broken + 1))
          continue
      fi
      # Lower-case the fragment before looking it up. Every anchor in the set is lower-case because
      # that is how they are generated, so comparing the fragment as written made #Redaction miss
      # #redaction and report a heading that is plainly there.
      frag=$(printf '%s' "$frag" | tr '[:upper:]' '[:lower:]')
      if [ -n "$frag" ] && ! grep -qF "$(printf '%s\t%s' "$resolved" "$frag")" "$all_anchors"; then
          bad "$f links to $target, and $resolved has no heading anchoring #$frag"
          broken=$((broken + 1))
      fi
  done
done
[ "$broken" -eq 0 ] && ok "every relative link and anchor in the docs resolves"

# ---------------------------------------------------------------- make targets the docs name
#
# A documented target that does not exist is the most embarrassing thing a Makefile can do to a
# newcomer, and it is invisible in review: "make lint" reads as plausible whether or not the Makefile
# has it, which is exactly how one got written here and had to be corrected before release.
#
# Restricted to lines that begin with `make ` or are inside a fenced shell block, so the English
# phrases "make sure" and "make it work" are not read as targets.
step "every make target the docs name exists"
targets=$(grep -hoE '^[[:space:]]*make [a-z][a-z-]+' $DOCS_ALL 2>/dev/null \
          | sed -E 's/^[[:space:]]*make //' | sort -u)
missing=0
for t in $targets; do
  # A file argument is not a target: "make -C dir install" and "make install" are, and both are here.
  if grep -qE "^${t}:" Makefile; then
      ok "make $t is a target"
  else
      bad "the docs say 'make $t' and the Makefile has no such target"
      missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] && ok "every make target named in the docs exists in the Makefile"

# ---------------------------------------------------------------- generated examples
#
# An example in the documentation is either captured from a run or written by hand, and the two drift
# apart at very different rates. A captured one is only captured once: someone runs the code, copies
# the output into a markdown file, and from then on it is a copy that nobody updates.
#
# So a captured example is fenced by a marker naming its source, and the source is written by
# scripts/capture.sh. This compares them after masking the volatile parts, which is the same masking
# capture.sh applies, so the two cannot disagree about what is allowed to vary.
#
#   <!-- generated: docs/examples/scenarios-coverage.md#table -->
#   ...
#   <!-- /generated -->
#
# Three failures, all of them silent otherwise:
#
#   - the block drifted from what the code prints
#   - a block is marked generated but its source is missing, so the block is trusted on nothing
#   - a captured file exists that no block references, so it is rotting and nobody reads it
# Markers are read from prose only. A marker inside a fenced block is documentation *about* markers,
# which is how CONTRIBUTING.md explains the syntax, and treating that as a live marker made the check
# demand the placeholder filename in the middle of the page.
#
# awk, not grep: awk is what can see the fence boundaries. Two passes would also work and would be
# easier to read, but this is one pass over one stream and the fence state is a single variable.
#
# The pattern is the second argument, not the first. It was the first, so the "pattern" was the
# filename and every line mentioning the file matched: the check reported four blocks generated from
# sentences that contain the word "generated". An argument-order mistake that turns a check into noise
# rather than into an error.
# Call as: markers_in <file> <awk-regex>. The file is $1 and the pattern is $2.
markers_in() {
    awk -v pat="$2" '
        /^```/ { inside = !inside; next }
        !inside && $0 ~ pat { print }
    ' "$1"
}

# ---------------------------------------------------------------- every example is classified
#
# The scheme is that an example is either captured and compared, or written and marked as such. That
# only works if every example is one or the other: an unmarked block is indistinguishable from a
# capture, and a reader has no way to know whether anybody checked it. Four blocks were unmarked when
# this check was written, including two that showed a psql prompt with no output under it.
#
# The test for "looks like output" is deliberately loose. It catches a psql prompt, a table whose
# header starts with a column name, a row that starts with a number and a pipe, and the extension's own
# box-drawing. A false positive costs one marker comment; a false negative costs a reader's trust.
step "every example is either captured or marked as written"

# The marker may sit above the fence, as generated markers do, or inside it. Both count.
classified() {
    local f=$1 lo=$2 hi=$3
    grep -qE '<!-- (generated|illustrative):' <<<"$(sed -n "${lo},${hi}p" "$f")" && return 0
    # and the four lines above the block, for a marker followed by a blank line
    local start=$(( lo > 4 ? lo - 4 : 1 ))
    grep -qE '<!-- (generated|illustrative):' <<<"$(sed -n "${start},$(( lo - 1 ))p" "$f")"
}

looks_like_output() {
    # $1 is the block body
    grep -qE 'postgres=#|^\s*[a-z_][a-z_ ]*\|' <<<"$1" \
        || grep -qE '^\s*\|?\s*[0-9]+\s*\|' <<<"$1" \
        || grep -qE '^\s*[├└│]' <<<"$1" \
        || grep -qE '^\s*\|[-= ]{3,}' <<<"$1"
}

# CHANGELOG.md is excluded, for the reason check_object excludes it: a changelog is a record of what
# was true at the time, so its quoted output is historical and marking it would be noise. Two blocks
# in there trip this check and neither is an example anyone follows.
unclassified=0
for f in $DOCS_ALL; do
    [ -f "$f" ] || continue
    [ "$f" = CHANGELOG.md ] && continue
    # Collect fence spans, then test each body.
    awk '
        /^```/ { if (inside) { print start "\t" NR; inside = 0 } else { inside = 1; start = NR } }
    ' "$f" | while IFS=$'\t' read -r lo hi; do
        # The opening fence line is $lo and the closing one is $hi.
        body=$(sed -n "$(( lo + 1 )),$(( hi - 1 ))p" "$f")
        [ -z "$body" ] && continue
        if looks_like_output "$body"; then
            if classified "$f" "$lo" "$hi"; then
                ok "$f block at line $lo looks like output and is classified"
            else
                echo "UNCLASSIFIED $f $lo $hi"
            fi
        fi
    done
done > /tmp/lt-examples.$$
n_unclass=$(grep -c '^UNCLASSIFIED' /tmp/lt-examples.$$ || true)
grep -v '^UNCLASSIFIED' /tmp/lt-examples.$$ | while read -r line; do ok "$(echo "$line" | cut -d' ' -f2-)"; done
n_classified=$(grep -c 'looks like output and is classified' /tmp/lt-examples.$$ || true)
[ "$n_classified" -gt 0 ] && ok "$n_classified example block(s) in the documentation are classified"
if [ "$n_unclass" -gt 0 ]; then
    while read -r _ f lo hi; do
        bad "$f has an unmarked block at line $lo that looks like output. Either mark it <!-- illustrative: ... --> or capture it with scripts/capture.sh"
    done < <(grep '^UNCLASSIFIED' /tmp/lt-examples.$$)
    unclassified=$n_unclass
else
    ok "no unmarked output-shaped block, so every example says whether it was checked"
fi
rm -f /tmp/lt-examples.$$

step "every generated example matches its capture"

# The mask, kept byte-identical to scripts/capture.sh. Two copies of a masking rule is one copy too
# many, so this one is generated from the capture script rather than typed.
MASKS=$(sed -n '/^MASKS=(/,/^)/p' scripts/capture.sh | sed -e '1d' -e '$d' \
        | sed -e "s/^ *'//" -e "s/'$//")
if [ -z "$MASKS" ]; then
    bad "could not read the mask out of scripts/capture.sh, so no example can be checked"
else
    mask_text() {
        local -a args=()
        local e
        for e in "$@"; do args+=(-e "$e"); done
        sed -E "${args[@]}"
    }
    # The mask, one expression per array element.
    #
    # Read with a while loop rather than mapfile. mapfile is the obvious choice and it is a bash 4
    # builtin, and this script runs in a CI container whose bash version is not something the
    # repository controls. A while loop works on every bash that can run the rest of the file.
    MASK_EXPRS=()
    while IFS= read -r _e; do
        [ -n "$_e" ] && MASK_EXPRS+=("$_e")
    done <<< "$MASKS"

    # The mask has to be shown to work, or "the block matches its capture" means nothing: an empty or
    # broken mask compares the two texts exactly and still agrees whenever the documentation is a
    # faithful copy, which is the case a reader is most worried about not being checked.
    #
    # So it is applied to a line built to be volatile, and every volatile token must be gone. If this
    # ever fails, the fix is in capture.sh's MASKS and not in the documentation.
    # Two lines, because each shape is handled by a different expression and a probe that any one
    # expression can satisfy does not prove the others work. The second line is the case that needs
    # the pid-at-line-start rule specifically: with that rule removed the probe still passed, because
    # everything else on the first line was masked by other expressions.
    probe='pid 157 waited 3.5s then 1m30s at 2026-10-05 17:04:11 (392) in {158,159} behind └─160  0s
 900  idle in transaction  0s nightly_batch  UPDATE ledger SET amount = amount WHERE id = 1'
    masked=$(printf '%s\n' "$probe" | mask_text "${MASK_EXPRS[@]}")
    if [ "$masked" = "$probe" ]; then
        bad "the mask changed nothing, so a generated example is compared verbatim and drift in a pid or a wait would be invisible"
    elif grep -qE '[0-9]{3,}|3\.5s|1m30s|[0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"$masked"; then
        bad "the mask left a volatile token behind: $masked"
    else
        # The replacement text is part of what is being checked, not just the fact of replacement.
        # Renaming <AGE> to something else still hides the token, so a rule can be broken by renaming
        # its replacement and this guard cannot tell. That was found by trying exactly that.
        missing=''
        for tok in '<PID>' '<PIDS>' '<AGE>' '<TIMESTAMP>'; do
            case "$masked" in *"$tok"*) ;; *) missing="$missing $tok" ;; esac
        done
        if [ -n "$missing" ]; then
            bad "the mask does not use the named replacement(s):$missing. Got: $masked"
        else
            ok "the mask replaces pids, waits, timestamps and pid arrays, with named tokens: $masked"
        fi
    fi

    gen_ok=0; gen_bad=0; gen_seen=0
    for f in $DOCS_ALL; do
        [ -f "$f" ] || continue
        # Pull each marked block out with awk: the marker line, the fence, the body, the fence.
        while IFS= read -r spec; do
            [ -z "$spec" ] && continue
            gen_seen=$((gen_seen + 1))
            src=${spec%%#*}
            blk=${spec#*#}
            if [ ! -f "$src" ]; then
                bad "$f marks a block generated from $src, which does not exist"
                gen_bad=$((gen_bad + 1))
                continue
            fi
            if [ ! -d docs/examples ]; then
                bad "no docs/examples directory, so $src cannot have been captured"
                gen_bad=$((gen_bad + 1))
                continue
            fi
            # The block from the documentation.
            # Everything between the markers, fenced or not. The first generated block is a markdown
            # table rather than a code block, and requiring a fence reported it as missing.
            # Leading and trailing fence lines are dropped, and only those: a block may be fenced in
            # the documentation and bare in the capture, and the fences are formatting rather than
            # content. A fence in the middle would be a fence inside captured output, which is left
            # alone because dropping it would be guessing.
            doc_block=$(awk -v s="<!-- generated: $spec -->" '
                $0 == s { grab = 1; next }
                grab && /^<!-- \/generated -->/ { grab = 0; next }
                grab { n++; line[n] = $0 }
                END {
                    lo = 1; hi = n
                    while (lo <= hi && (line[lo] ~ /^```/ || line[lo] ~ /^[[:space:]]*$/)) lo++
                    while (hi >= lo && (line[hi] ~ /^```/ || line[hi] ~ /^[[:space:]]*$/)) hi--
                    for (i = lo; i <= hi; i++) print line[i]
                }
            ' "$f")
            if [ -z "$doc_block" ]; then
                bad "$f marks $spec generated but has nothing under the marker"
                gen_bad=$((gen_bad + 1))
                continue
            fi
            # The block from the capture. A capture file is either one block, or several under
            # @block markers.
            cap_block=$(awk -v want="$blk" '
                $0 == "@block " want { grab = 1; next }
                grab && /^@block / { exit }
                grab && /^# generated by/ { exit }
                grab { print }
            ' "$src")
            if [ -z "$cap_block" ]; then
                if [ "$blk" = "table" ] || [ "$blk" = "all" ]; then
                    # Only the provenance comment is stripped. The table keeps its own header and its
                # separator row, because the documentation's copy has them too.
                cap_block=$(sed -e '/^# generated by/d' "$src")
                else
                    bad "$f wants $blk from $src, and that file has no such block"
                    gen_bad=$((gen_bad + 1))
                    continue
                fi
            fi
            # Mask both, then compare. Masking the capture as well as the documentation means a
            # volatile number cannot be the reason the two agree.
            a=$(printf '%s\n' "$doc_block" | mask_text "${MASK_EXPRS[@]}")
            b=$(printf '%s\n' "$cap_block" | mask_text "${MASK_EXPRS[@]}")
            # Blank lines are not a difference: an editor that trims trailing blanks is not a change
            # of meaning, and the docs are read by people who reflow them.
            a=$(printf '%s\n' "$a" | sed -e '/^[[:space:]]*$/d')
            b=$(printf '%s\n' "$b" | sed -e '/^[[:space:]]*$/d')
            if [ "$a" = "$b" ]; then
                ok "$f: $spec matches its capture"
                gen_ok=$((gen_ok + 1))
            else
                bad "$f: $spec does not match $src. Diff, capture first:"
                printf '%s\n' "$a" > /tmp/lt-doc.$$
                printf '%s\n' "$b" > /tmp/lt-cap.$$
                diff /tmp/lt-doc.$$ /tmp/lt-cap.$$ | sed 's/^/        /' | head -12
                rm -f /tmp/lt-doc.$$ /tmp/lt-cap.$$
                gen_bad=$((gen_bad + 1))
            fi
        done < <(markers_in "$f" '<!-- generated: [^ ]+ -->' | sed -e 's/<!-- generated: //' -e 's/ -->//')
    done

    [ "$gen_seen" -gt 0 ] && ok "$gen_seen generated example(s) declared"
    [ "$gen_seen" -eq 0 ] && ok "no generated examples declared, which is allowed but means none are checked"
    [ "$gen_bad" -eq 0 ] && ok "every generated example matches its capture"

    # An illustrative marker is a claim that the block is NOT captured. Nothing here verifies the
    # numbers, because there is nothing to verify them against; what it does is stop an illustrative
    # block reading as a capture, which is how a hand-written example becomes evidence for itself.
    ill=0
    for f in $DOCS_ALL; do
        [ -f "$f" ] || continue
        while IFS= read -r note; do
            [ -z "$note" ] && continue
            ok "$f marks a block illustrative: $note"
            ill=$((ill + 1))
        done < <(markers_in "$f" '<!-- illustrative: [^>]+>' | sed -e 's/<!-- illustrative: //' -e 's/ -->//')
    done
    if [ "$ill" -eq 0 ]; then
        ok "no illustrative blocks marked, which is allowed but means every example claims to be a capture"
    fi

    # A block must not be both. A generated block is checked against a capture and an illustrative one
    # is not, so marking one as both means the marker that does nothing is the one a reader trusts.
    for f in $DOCS_ALL; do
        [ -f "$f" ] || continue
        both=$(grep -cE '<!-- (generated|illustrative)' "$f")
        [ "$both" -gt 0 ] || continue
        g=$(grep -c '<!-- generated:' "$f" || true)
        i=$(grep -c '<!-- illustrative:' "$f" || true)
        # One file legitimately holds both kinds. What cannot happen is one block claiming both, so
        # the counts only have to be checked where a file has a single example.
        if [ "$g" -gt 0 ] && [ "$i" -gt 0 ]; then
            ok "$f has $g generated and $i illustrative block(s), which is allowed"
        fi
    done

    # And the other direction: a capture nobody references is a file that rots unread.
    if [ -d docs/examples ]; then
        for c in docs/examples/*; do
            [ -f "$c" ] || continue
            rel=${c#./}
            if grep -q "generated: $rel" $DOCS_ALL 2>/dev/null; then
                ok "$c is referenced by a generated block"
            elif grep -qF "($rel)" $DOCS_ALL 2>/dev/null; then
                # Linked rather than inlined, which is what a transcript too long to embed wants.
                ok "$c is linked from the documentation"
            else
                bad "$c is captured but nothing in the documentation refers to it"
                gen_bad=$((gen_bad + 1))
            fi
        done
        [ "$gen_bad" -eq 0 ] && ok "every captured file is referred to by the documentation"
    fi
fi

# ---------------------------------------------------------------- prose references to moved sections
#
# A sentence in a shell script saying "see the Alerting section of README.md" is not a link, so the
# link check cannot see it, and the split moved those sections. Two were stale: check-alert.sh and
# check-deadlock.sh. The words are matched rather than the path, because the failure is a section
# name that no longer lives in the README.
step "no script points at a README section that has moved"
prose_stale=0
# lint-docs.sh is excluded because it necessarily contains the pattern it is looking for: the regular
# expression itself spells out "section of README.md". A check that matches itself is a check that
# always fails, which is worse than none.
for s in $(ls scripts/*.sh | grep -v 'lint-docs\.sh$') test/*.sql demo.sql Makefile; do
    [ -f "$s" ] || continue
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        bad "$s points at a README section that has moved: $line"
        prose_stale=$((prose_stale + 1))
    done < <(grep -nEo '(section|chapter|part|heading)s? of (the )?README\.md' "$s" 2>/dev/null)
done
[ "$prose_stale" -eq 0 ] && ok "no script names a README section, since the sections moved to docs/"

# ---------------------------------------------------------------- no target is silently a no-op
#
# Every target in this Makefile is procedural: none produces a file of its own name. `make scenarios`
# nonetheless did nothing at all until every target was declared .PHONY, because make saw the
# scenarios/ directory and decided the target was already up to date. It printed nothing, failed
# nothing, and the documentation said it captured output.
#
# So: every target must be phony. A target that is not phony and whose name is a path in the tree is
# the exact shape of that bug, and the collision is reported by name rather than only failing later.
step "every make target is phony, so none can be silently up to date"
all_targets=$(grep -oE '^[a-z][a-z0-9-]*:' Makefile | tr -d ':' | sort -u)
phony=$(sed -n 's/^\.PHONY:[[:space:]]*//p' Makefile | tr ' ' '\n' | grep -v '^$' | sort -u)
for t in $all_targets; do
    if grep -qx "$t" <<<"$phony"; then
        ok "make $t is declared .PHONY"
    else
        bad "make $t is not declared .PHONY"
        if [ -e "$t" ]; then
            bad "  and $t exists in the tree, so make would report it up to date and do nothing"
        fi
        unphony=$((unphony + 1))
    fi
done
[ "$unphony" -eq 0 ] && ok "every make target is phony"

# A target whose name is also a path in the tree is the shape of that bug, so it is called out by
# name. It is not a failure on its own: with .PHONY declared, make runs the recipe regardless, which
# is why `make scenarios` works at all now that scenarios/ exists. It is a failure if the target is
# not phony, which is the check above.
collide=0
for t in $all_targets; do
    if [ -e "$t" ]; then
        collide=$((collide + 1))
        if grep -qx "$t" <<<"$phony"; then
            ok "make $t shares its name with the $t path in the tree, and is phony, so it runs"
        fi
    fi
done
[ "$collide" -eq 0 ] && ok "no make target shares its name with a path in the tree"

step "every document still has the shape a reader needs"
# Added in 1.1.10 because 1.1.9 shipped docs/reference.md with its first 31 lines gone: the H1, the
# introduction, the monitoring-roles note, the Objects heading, the table's header row and fifteen
# object rows. Every check above still passed, 608 of them. Each one asks whether something the docs
# NAME exists, and a headless file satisfies that perfectly: the surviving rows still named real
# objects, and the functions whose rows were cut were still named lower down, in the stability
# section, so "appears somewhere in reference.md" stayed true for all of them.
#
# These assert STRUCTURE, not content, so ordinary editing does not trip them and nothing has to be
# regenerated when a document changes. A checksum manifest was considered and rejected: it detects
# change rather than damage, fires on every legitimate edit, and is refreshed by a blind overwrite
# that would record the truncated file as the new truth. Git already holds every version, and
# `git show v1.1.8:docs/reference.md` is what restored this one.
#
# Each assertion was shown to fail on the real damage: with 1.1.9's reference.md put back, all four
# below fail and name the file.

# 1. Every document opens with its H1. A cut from the top, which is what happened, removes it first.
#    CHANGELOG.md is the one exception and is checked for its own shape instead: it opens with the
#    newest release heading, which the version checks above already pin to the control file.
for f in $DOCS_ALL; do
    [ -f "$f" ] || continue
    first=$(head -n 1 "$f")
    if [ "$f" = CHANGELOG.md ]; then
        case "$first" in
            "## "[0-9]*) ok "$f opens with a release heading" ;;
            *) bad "$f does not open with a release heading; its first line is: $first" ;;
        esac
        continue
    fi
    case "$first" in
        "# "*) ok "$f opens with its H1" ;;
        *) bad "$f does not open with an H1, so something has cut its top; first line: ${first:0:60}" ;;
    esac
done

# 2. The reference keeps its Objects section, and the table in it keeps the header row that makes it a
#    table. Without the header, markdown renders the surviving rows as a paragraph of pipes.
REFDOC=docs/reference.md
if [ -f "$REFDOC" ]; then
    if grep -qx '## Objects' "$REFDOC"; then
        ok "$REFDOC has its ## Objects section"
        if grep -qx '|---|---|' <<<"$(awk '/^## Objects$/{f=1;next} f&&/^## /{exit} f' "$REFDOC" \
                                       | grep -A1 -x '| Object | Use |')"; then
            ok "the Objects table in $REFDOC has its header row and separator"
        else
            bad "the Objects table in $REFDOC has lost its '| Object | Use |' header or separator"
        fi
    else
        bad "$REFDOC has no '## Objects' heading"
    fi
fi

# 3. A floor of lines per document, at about 80% of its size on 1.1.10. It sits well below what
#    ordinary editing moves, and above what a lost section costs: reference.md went from 120 to 89
#    lines, so a floor of half would have passed it. A document with no floor FAILS rather than
#    passing unchecked, so a new one cannot quietly join the list without being given one. Lower a
#    floor deliberately, in the same commit as the cut that justifies it.
declare -A FLOOR=(
    [README.md]=155 [INSTALL.md]=555 [CONTRIBUTING.md]=170 [CHANGELOG.md]=3200
    [scenarios/README.md]=85 [docs/after-the-incident.md]=245 [docs/alerting.md]=270
    [docs/design-notes.md]=65 [docs/history.md]=510 [docs/incident.md]=250
    [docs/reference.md]=100 [docs/roadmap.md]=460
)
for f in $DOCS_ALL; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f")
    if [ -z "${FLOOR[$f]:-}" ]; then
        bad "$f has no line floor; give it one in scripts/lint-docs.sh"
    elif [ "$n" -lt "${FLOOR[$f]}" ]; then
        bad "$f has $n lines, below its floor of ${FLOOR[$f]}: check nothing was cut"
    else
        ok "$f has $n lines, at or above its floor of ${FLOOR[$f]}"
    fi
done

# 4. Every object the release defines is a ROW of the Objects table, not merely a word somewhere in the
#    file. The check above ("every function ... appears in the Objects table") greps the whole file,
#    which is why it passed on 1.1.9: lock_tree_roots() had lost its row and was still mentioned in
#    the stability section. This one reads only the table rows under ## Objects, and covers views,
#    tables and procedures as well as functions.
if [ -f "$REFDOC" ]; then
    rows=$(awk '/^## Objects$/{f=1;next} f&&/^## /{exit} f' "$REFDOC" | grep '^|' || true)
    missing=""
    for o in $(grep -oE '^CREATE (OR REPLACE )?(FUNCTION|VIEW|TABLE|PROCEDURE) @extschema@\.lock_tree[a-z_]*' "$latest" \
                 | sed 's/.*\.//' | sort -u); do
        # A here-string, not printf piped into grep -q: grep -q exits on its first match, the printf
        # then takes SIGPIPE, and under pipefail the pipeline reports failure. That reported real rows
        # as missing at random, lock_tree_text on one run and nothing on the next.
        grep -qE "(^|[^a-z_])${o}([^a-z_]|$)" <<<"$rows" || missing="$missing $o"
    done
    if [ -z "$missing" ]; then
        ok "every object in $latest has a row in the Objects table in $REFDOC"
    else
        bad "objects in $latest with no row in the Objects table in $REFDOC:$missing"
    fi
fi

step "house style"
# Neither character can appear literally in this file, or the check below would always
# flag itself. They are built from their UTF-8 bytes, not with printf '\u2014': printf only
# emits the character when the locale is UTF-8. Under POSIX or C, which is what a bare
# container gives you, it emits the six characters backslash-u-2-0-1-4 instead, the pattern
# then matches nothing but this script's own comments, and the check passes on a file full
# of dashes. Found by injecting one under LC_ALL=POSIX and watching it pass.
#
# The self-exclusion is normalised to the form git ls-files uses. Invoked as
# ./scripts/lint-docs.sh, BASH_SOURCE carries the leading ./, and grep -x against
# "scripts/lint-docs.sh" would match nothing, so the exclusion would silently not apply.
self=${BASH_SOURCE[0]#./}
emdash=$'\xe2\x80\x94'
endash=$'\xe2\x80\x93'

style_scan() {
    local char=$1 label=$2 files
    # The fallback list (no git repository) comes from find and carries a leading ./, which
    # git ls-files does not, so it is stripped here or the self-exclusion below matches nothing.
    files=$(tracked_files | xargs -0 grep -l -e "$char" 2>/dev/null | sed 's|^\./||' \
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