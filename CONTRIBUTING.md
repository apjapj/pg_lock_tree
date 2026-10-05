# contributing: changing this, and releasing it

**For: whoever changes the SQL, the tests or the documentation, and whoever tags a release.** The make
targets, the test suite, the version matrix, and the release checklist.

`make check` needs no database and is the one to run first: it is the documentation lint, and it is
what catches a rename that half the documentation has not caught up with.

## Make targets

```bash
make check              # the checks that need no server: the documentation lint, and a note
make lint-docs          # documentation, objects, paths, links and anchors, and the test table
make prove              # 409 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all eight scenarios, both tools, output captured
make check-alert        # prove a real NOTIFY reaches a real listening client
make check-deadlock     # prove a real deadlock moves the counter and the sample records it
make check-deadlock DEADLOCK_TIMEOUT=15s   # same, with s6's timeout: proves the cycle AND the count
make bench-history      # time the read side against a synthetic 1.2M row history (truncates it)
make check-upgrade      # every upgrade path ends in the same objects as a fresh install
make check-schema       # install into a private schema, then use it from a caller that cannot see it
make explain-alert PAYLOAD='…'   # explain a payload you already have, no database needed

scripts/matrix.sh       # install + CREATE EXTENSION + tests on PG 14 to 19 in the docker matrix
```

## Tests

The tests need superuser and the `dblink` contrib module, because they open real sessions and
terminate backends rather than mocking anything:

| file | covers |
|---|---|
| `test/01_lock_tree.sql` | a real five-session chain: roots, depth, paths, multiple blockers, wait details, the root summary, text output, that the tree empties when the root rolls back, and that the description and command halves of the action block stay apart |
| `test/02_permissions.sql` | the grants a monitoring role needs, including that `pg_read_all_stats` alone is not enough |
| `test/03_deadlock.sql` | a real two-session wait-for cycle, and that the tree does not go empty |
| `test/04_prepared.sql` | a prepared transaction as root pid 0, including that its advice is `ROLLBACK PREPARED` rather than a cancel against a backend that does not exist. Skips itself when `max_prepared_transactions` is 0 |
| `test/05_formatting.sql` | the exact output of the rendering helpers, since the width measurements depend on them |
| `test/06_cron.sql` | a live chain sampled by a `pg_cron` job, proving the rows outlive the incident. Skips itself when `pg_cron` is not preloaded |
| `test/07_history.sql` | a live chain sampled into `lock_tree_history`, the rows surviving the incident, the history segmented into incidents, and pruning at both extremes. No `pg_cron` needed |
| `test/08_wide.sql` | a 57-row, two-root queue, checked against `lock_tree` row by row: every count in the wide form must be derivable from the tree, since a summary that disagrees with the tree is worse than none |
| `test/09_cost.sql` | the cost claim the README and the SQL header both make, measured as a ratio against a plain `pg_stat_activity` read rather than a wall-clock ceiling, which is noise on a shared runner |
| `test/10_statements.sql` | `lock_tree_statements()` with and without `pg_stat_statements` loaded: the roots are reported either way, and the join is pinned where it is available |
| `test/11_alert.sql` | alerting, and mostly not alerting: onset fires once, an unchanged chain stays silent, escalation fires on width, on depth and on a doubling wait, `min_wait => NULL` suppresses age escalation entirely, recovery then relapse fires again, and all three thresholds disabled is an error |
| `scripts/check-alert.sh` | the delivery path, which no assertion can check: psql prints notifications to stdout, so this listens from a second client and reads the payload back. `--explain` turns a payload into the queries to run, with no database |
| `scripts/check-deadlock.sh` | that a **real** deadlock moves the counter and the sample records it. Separate process, because the increment lands on a timer and three attempts inside one psql session all failed |
| `test/12_history_statements.sql` | per-query blocking time from written history: only root rows count, the window filter runs before the aggregation, and the figure is session-samples rather than seconds |
| `test/13_prepared_roots.sql` | two prepared transactions are two roots, which is the 0.8 bug: the waiters attach to the right object, every aggregate counts two roots, and alerting tracks them separately |
| `test/14_deadlocks.sql` | the deadlock counter: a sample on a quiet tree still records it, a delta is a subtraction and never negative, a reset is reported as a reset, and the sampling advice is sized on the history's peak rather than on the instant |
| `test/15_history_size.sql` | the sizing report (zeros and NULLs on an unsampled database, a real rate when there is one), and that a `CALL` inside a transaction block is refused **having deleted nothing** |
| `test/16_duration_resolved.sql` | the resolution notices: nothing on a quiet database, one when an alerted root leaves the tree, and that a root which never alerted produces nothing |
| `test/17_duration_by_application.sql` | per-application blocking time, and the two directions in which it and the per-query figure invert: different statements in one application, and the same statement across two applications. Its expectations are derived from the sample rows rather than from the function under test, because a version that computed them from the same join agreed with a bug in it |
| `test/18_replay.sql` | replaying an incident that has ended: the nearest-sample rule, tie-breaking, a target before the first sample, and the columns replay carries that the live view does not, asserted **by name** so adding one is noticed |
| `test/19_index_usage.sql` | that the fifteen window bounds SEEK rather than filter over the whole index, which is the one bug here that no correctness test could see: they used `clock_timestamp()`, which is `VOLATILE`, so the planner could not use them as index bounds. Asserts on the plan, never on elapsed time, because a time bound passes vacuously on a warm cache |
| `test/21_redaction.sql` | the credentials `lock_tree_redact()` must catch, including the five it must not, and the deliberate over-redaction of `VALID UNTIL` |
| `test/22_schema_install.sql` | installed in a private schema: nothing lands in `public`, the two `search_path`-pinned functions resolve from a caller that cannot see the extension, and `pg_dump` registers none of the three tables |

There is no `test/20`. Nothing was ever written at that number, and renumbering to close the gap
would change three filenames in the history for no benefit.

### A test that cannot fail is not a test

Two of these deserve their own note, because both were written to pass and neither had been shown to
fail.

A **negative check that passes on an empty set** is the easiest kind to get wrong. `test/22` asserts
that `lock_tree_sample()` cannot be reached unqualified from outside a private schema, and the first
version of the plant did not reach the catalog at all, so the assertion had never run against a
defective function. The header says so. The fix is to watch the check fail on a planted defect, and
if the plant cannot be made to reach the code, say so rather than counting the assertion.

A **check at an ignored severity** is worse than no check. pgTAP's `is()` and `ok()` are the floor;
anything at `TODO` or `SKIP` records intent and verifies nothing. The lint script counts the
assertions it expects against the ones it finds, and treats a shortfall as a note and an excess as a
failure, because an assertion that appeared without being counted is an assertion nobody reviewed.

## The matrix

CI runs the same suite on all six versions. Three files each need a server setting the matrix
images provide (`max_prepared_transactions`, `shared_preload_libraries` for `pg_cron` and
`pg_stat_statements`) and skip themselves where it is absent, rather than failing a build that
was never going to work. None is a runtime requirement: `pg_lock_tree` itself needs no
`shared_preload_libraries`, and the rest of the suite runs without them.

PostgreSQL 14 reaches end of life on 2026-11-12, which removes the bottom of the matrix. That is a
scheduling fact rather than a code change, and [INSTALL.md](INSTALL.md) records it.

## Examples: captured or written

Every example in the documentation is one of two things, and the difference matters because only one of
them can be checked.

**Captured.** `scripts/capture.sh` runs the code, masks the parts that move between runs, and writes
the result to `docs/examples/`. The documentation holds a copy fenced by

```
<!-- generated: docs/examples/<file>#<block> -->
```

and [`lint-docs.sh`](scripts/lint-docs.sh) compares the two. Change what the code prints and the
documentation fails. There are four: the lock tree in the README, the actions block and the single
command beside it, the order the demo prints, and the coverage table in `scenarios/README.md`, which was
the last hand-transcribed set of numbers in the repository.

**Written.** Shortened for reading: round pids, every wait `0s`, statements trimmed to the part that
matters. There are none left in the README: both of its transcripts became captures, which is why the
demo had to build the incident the README illustrates rather than a similar one. Elsewhere they are
fenced by

```
<!-- illustrative: ... -->
```

and nothing checks them, because there is nothing to check them against. The marker exists so that a
hand-written example cannot be read as evidence for itself.

Adding a third kind is the thing to avoid. If an example can be made to come from a real run, make it
come from a real run: a written example of something the code can print is an example that will
eventually be wrong.

The mask is in `scripts/capture.sh` and is read out of that file by `scripts/lint-docs.sh`, so
there is one copy. Every substitution has a named replacement, `<PID>`, `<PIDS>`, `<AGE>`, `<TIMESTAMP>`, so a diff
shows what was hidden rather than that something was. It deliberately does not mask the coverage
numbers in the scenarios table, because masking the thing under test is not a check.

`make capture` needs a server with the extension installed, so it is not part of `make check`. Run it
after changing anything that prints, and commit what it writes.

Only the demo's section list and the scenarios coverage table are compared, and the files holding them
are named in the markers above. The full transcript in the examples directory is a linked artifact for
a reader and is deliberately not compared: psql right-aligns a
numeric column to its widest value, so the mask changes the layout, and notices depend on the
server's history rather than on the code. A generated block pointing at the transcript would fail on
whitespace alone.

## Proving a check fails

A check that has never failed is not a check. This repository has three tests of its own tests, each
because a check once passed on something it should have caught.

**Plant the defect, reinstall, then run.** The step that gets skipped is the middle one. Every check
that reads the installed catalog sees an unchanged catalog if you only edit the file, so:

```bash
# 1. break exactly one thing, and make the break small enough to name in a sentence
$EDITOR pg_lock_tree--1.0.1.sql          # FROM @extschema@.lock_tree_roots()  ->  FROM lock_tree_roots()

# 2. reinstall. Without this the next command tests nothing.
docker exec lt bash -lc 'cd /src && make -s install'
psql -X -c 'DROP EXTENSION pg_lock_tree;' -c 'CREATE EXTENSION pg_lock_tree;'

# 3. run the check and watch it fail. A check that passes here tells you the plant did not land,
#    which is worth knowing before you change the check.
pg_prove --dbname postgres test/22_schema_install.sql

# 4. restore, reinstall, and run it again to see it pass
git checkout pg_lock_tree--1.0.1.sql
```

The trap this replaces: an earlier attempt planted the defect, skipped the reinstall, saw the test
pass, and recorded that the check's non-vacuity was unproved. It was not unproved; the catalog had
never changed. Every negative check in this repository needs all four steps, and "the test passed" is
only evidence once step 2 has actually happened.

**Two more shapes worth recognising:**

- **An assertion count on an empty set.** `scripts/lint-docs.sh` counts the assertions it expects
  against the ones it finds, and treats a shortfall as a note and an excess as a failure, because an
  assertion that appeared without being counted is one nobody reviewed.
- **A check at an ignored severity.** A `TODO` or `SKIP` records intent and verifies nothing, and is
  worse than no check because it reads as coverage.

## Releasing

Every release is additive: a new full-version script plus an update path from the version
before it, both named the way the release files already in the tree are named. An existing
installation therefore never has to reinstall to get a fix.

1. **Bump the version.** The control file, the new full-version script, and the changelog heading.
   `scripts/lint-docs.sh` reads the control file and the README and fails if they disagree, and also
   fails if the control file names a version with no script for it, so a missed bump is caught
   rather than shipped.
2. **Write the update script**, and read it against the previous release's file. Most of the work in
   an update is arriving at the same catalog state a fresh install would.
3. **`make check-upgrade`.** Every path from every earlier version has to converge on the same
   objects as a fresh install. Column position is the one difference that cannot be made consistent,
   because `ALTER TABLE ADD COLUMN` appends, and it is a named exception that is checked in both
   directions so the list cannot rot into a permanent exemption.
4. **The full suite on every version**, `scripts/matrix.sh`, not one version.
5. **`make lint-docs`**, which is the documentation, the objects it names, the paths it links to, the
   links and anchors, the test table and the version the README claims against the control file. The
   secrets are two separate CI jobs rather than a make target: gitleaks over the history and
   detect-secrets over the tree at HEAD, and gitleaks also runs as a fail-closed pre-commit hook. So a
   secret stops the commit and a broken anchor stops the pipeline, and neither depends on the other.
6. **Run the demonstrations**, `make demo` and `make scenarios`, and compare them against what the
   documentation claims. The scenario demos print the popular standard DBA query beside this
   extension's output, and the captured output is the proof that the two agree.
7. **Commit, push, tag, push the tag.** Push the commit before the tag, never in the same command:
   `git push --tags` in a command whose commit was rejected by a hook pushes a tag that points at
   the previous release, and that happened at 1.0.0.
8. **Never amend a pushed tag.** If a tag is wrong, delete it, push the deletion, and tag again, and
   say so in the changelog with the `git fetch --tags --force` that anyone who already fetched the
   bad tag needs.
9. **Record what could not be verified.** A claim that was taken from someone else's testing is
   written as such, in the same words, until someone has run it. That has already happened once at
   1.0.1 for the deadlock log line, and the changelog records both the original claim and how it was
   finally checked.