# contributing: changing this, and releasing it

**For: whoever changes the SQL, the tests or the documentation, and whoever tags a release.** The make
targets, the test suite, the version matrix, and the release checklist.

`make lint` needs no database and is the one to run first: it is the documentation lint, and it is
what catches a rename that half the documentation has not caught up with.

## Make targets

```bash
make lint               # the checks that need no server: the documentation lint, and a note
make lint-docs          # documentation, objects, paths, links and anchors, and the test table
make prove              # 503 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all eight scenarios, both tools, output captured
make check-alert        # prove a real NOTIFY reaches a real listening client
make check-deadlock     # prove a real deadlock moves the counter and the sample records it
make check-deadlock DEADLOCK_TIMEOUT=15s   # same, with s6's timeout: proves the cycle AND the count
make bench-history      # time the read side against a synthetic 1.2M row history (truncates it and the archive)
make check-upgrade      # every upgrade path ends in the same objects as a fresh install, plus the 1.1.8 dependents refusal
make check-schema       # install into a private schema, then use it from a caller that cannot see it
make defects            # re-inject every recorded defect (defects/); the test must fail on each
make explain-alert PAYLOAD='…'   # explain a payload you already have, no database needed

scripts/matrix.sh       # install + CREATE EXTENSION + tests on PG 14 to 19 in the docker matrix
```

## Tests

The tests need superuser and the `dblink` contrib module, because they open real sessions and
terminate backends rather than mocking anything:

| file | covers |
|---|---|
| `test/01_lock_tree.sql` | a real five-session chain: roots, depth, paths, multiple blockers, wait details, the root summary, text output, that the tree empties when the root rolls back, and that the description and command halves of the action block stay apart |
| `test/02_permissions.sql` | the grants a monitoring role needs: that `pg_read_all_stats` alone is not enough, that `lock_tree_notify()` needs all four privileges on `lock_tree_alert` rather than one, and what `pg_dump` does and does not carry |
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
| `test/23_archive.sql` | the cold tier: that the move loses nothing, which is the assertion that fires if the batch is taken twice rather than captured once; that `lock_tree_redact()` runs on the way across; that the procedure refuses inside a transaction block **before** moving a row; that nothing shipped reads the archive; and the four privileges it needs. The fixture puts twenty rows on each `sampled_at` and archives in batches of seven, so every batch boundary lands inside a tie, which is what makes the loss bug fire rather than pass by luck. The grant checks assert by row count rather than `throws_ok`, because a procedure that COMMITs is refused inside the subtransaction those wrap in, so the call under test never runs. It also carries the 1.1.7 assertions that `lock_tree_history_size()` reports the archive, that the eight columns it already returned are unchanged, and that `archive_bytes` follows the archive rather than the hot table |
| `test/24_archive_find.sql` | searching the archive: that a NULL window is **refused**, that the guard `PERFORM` comes before the query rather than merely being in the body, that the result is one row per sample rather than per session, that each filter narrows the answer, and the three 1.1.9 corrections: `samples` is absent from the OUT columns, `%` and `_` in `waiting_like` are literals so a name that does not exist returns nothing, and a `since` wider than the archive is accepted rather than refused |
| `test/25_first_waiting_for.sql` | that `lock_tree_wide().first_waiting_for` is what the longest waiter wants: one root, two waiters on two tables, the older one on the table that sorts last, so `min()` and "first" disagree and the test can tell which it got |
| `test/26_resolve_reblock.sql` | a root that comes back while it is being resolved: that `lock_tree_notify_resolved()` reports it cleared **and** forgets it in one statement, so the next `lock_tree_notify()` alerts again rather than treating a live incident as already alerted and going quiet. The window is opened with a `search_path` that puts a `pg_notify` re-establishing the incident ahead of `pg_catalog`'s, and a trap assertion checks the root really is blocking again, so the file cannot pass by not reproducing |
| `test/27_grants.sql` | the grant matrix INSTALL.md describes: one superuser blocker and waiter through dblink, then the four roles (no grants, `pg_monitor` only, `SELECT` on the view only, both). Pins that `pg_monitor` is still denied, that `SELECT` alone shows no other session, and that `lock_tree_sample()` needs its own `EXECUTE` |
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

`make capture` needs a server with the extension installed, so it is not part of `make lint`. Run it
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
$EDITOR pg_lock_tree--1.1.0.sql          # FROM @extschema@.lock_tree_roots()  ->  FROM lock_tree_roots()

# 2. reinstall. Without this the next command tests nothing.
docker exec lt bash -lc 'cd /src && make -s install'
psql -X -c 'DROP EXTENSION pg_lock_tree;' -c 'CREATE EXTENSION pg_lock_tree;'

# 3. run the check and watch it fail. A check that passes here tells you the plant did not land,
#    which is worth knowing before you change the check.
pg_prove --dbname postgres test/22_schema_install.sql

# 4. restore, reinstall, and run it again to see it pass
git checkout pg_lock_tree--1.1.0.sql
```

The trap this replaces: an earlier attempt planted the defect, skipped the reinstall, saw the test
pass, and recorded that the check's non-vacuity was unproved. It was not unproved; the catalog had
never changed. Every negative check in this repository needs all four steps, and "the test passed" is
only evidence once step 2 has actually happened.

A recorded defect is that plant kept permanently. `defects/` holds each one as the reverse of its fix,
and `make defects` loads the clean release script and the patched one into two fresh servers and
requires the test to pass on the first and fail on the second, then reports a regression rate, so a
fix a later change stops catching is red rather than forgotten. See `defects/README.md`.

**Copying a file into a test container by hand: check the copy landed.** A copy that silently does
nothing means the next check reports a result about code that is not installed, and that is how two
separate defects in this project presented as passing tests. A container has no history, so nothing
else will notice: git cannot see it, and the extension directory looks exactly as it did.

This is for a human moving a file by hand, with `docker cp` and a `cp` inside the container. It is not
needed for `scripts/matrix.sh` or the `make -s install` in step 2 above, which copy the whole source
tree and delegate to `make install`, so PGXS installs exactly what the Makefile lists: no
hand-named destination, no glob, no shell quoting to get wrong. When copying by hand:

- **Name the destination file.** A `cp` whose destination is the extension directory itself installs
  the file under its temporary source name, which PostgreSQL never looks for.
- **Take the list of files from an explicit list, not a glob.** A glob skips a file that does not
  exist yet without a word, which is how eight files were "verified" while one was never copied.
- **Quote the inner `$(pg_config ...)`** in a `docker exec ... sh -c`. Unquoted, it expands on the
  host, where it is empty, and the `cp` fails with a path error that a `2>/dev/null` hides.
- **`md5sum` the destination and compare it with the source**, and treat a mismatch as a failed
  install, not noise.

**Two more shapes worth recognising:**

- **An assertion count on an empty set.** `scripts/lint-docs.sh` counts the assertions it expects
  against the ones it finds, and treats a shortfall as a note and an excess as a failure, because an
  assertion that appeared without being counted is one nobody reviewed.
- **A check at an ignored severity.** A `TODO` or `SKIP` records intent and verifies nothing, and is
  worse than no check because it reads as coverage.

## Workflow policy

Three rules every workflow in this repository follows, so a change to one file does not
quietly break the posture the others keep:

- **Actions are pinned to a commit SHA**, with the release in a trailing comment:
  `actions/checkout@<40-hex> # v4.4.0`. A tag such as `@v4` is a moving reference: whoever
  controls the upstream tag controls what runs in this repository, and the change lands
  without a review here. To move it, resolve the tag yourself
  (`git ls-remote https://github.com/actions/checkout refs/tags/v4`), replace the SHA, and
  put the new version in the comment in the same commit, so the diff shows both.
- **`permissions: contents: read` at the top of every workflow.** No job here writes to
  the repository, creates a release, or needs a wider token. Stating it means a later
  change cannot quietly widen it, and it stops a workflow inheriting whatever the
  repository default happens to be.
- **The Forgejo and GitHub copies are kept deliberately parallel.** They differ only in
  `runs-on`, the job image note and the log-retention sentence. They are not kept in step
  by a generator, because the point of the second copy is that the public repository
  proves what the private one proves, and a generator is one more thing that can be
  right while both copies are wrong. When you change one, change the other, and say in the
  commit that you did.

## Releasing

Every release is additive: a new full-version script plus an update path from the version
before it, both named the way the release files already in the tree are named. An existing
installation therefore never has to reinstall to get a fix.

1. **Bump the version.** The control file, the new full-version script, and the changelog heading.
   `scripts/lint-docs.sh` reads the control file and the README and fails if they disagree, and also
   fails if the control file names a version with no script for it, so a missed bump is caught
   rather than shipped. It also fails when the control version has no tag, which is correct between
   this step and the tag at step 8: run it with `LINT_ALLOW_UNTAGGED_RELEASE=1` while a bump is
   waiting for its tag, and stop setting the variable once the tag exists.
2. **Write the update script**, and read it against the previous release's file. Most of the work in
   an update is arriving at the same catalog state a fresh install would.
3. **`make check-upgrade`.** Every path from every earlier version has to converge on the same
   objects as a fresh install. Column position is the one difference that cannot be made consistent,
   because `ALTER TABLE ADD COLUMN` appends, and it is a named exception that is checked in both
   directions so the list cannot rot into a permanent exemption.
4. **The full suite on every version**, `scripts/matrix.sh`, not one version.
5. **`make check-examples`.** The SQL examples in the documentation are planned against the release
   being shipped, which needs a server with the extension installed, so it is not in `make lint`
   (that runs `lint-docs` alone). It is on the list because `SELECT * FROM lock_tree_replay(42)` sat in
   `docs/after-the-incident.md` from 0.14 onwards, calling a function that takes a `timestamptz` and
   has never taken anything else. A wrong example is as wrong as a wrong function, and this is the
   only thing that notices.
6. **`make lint-docs`**, which is the documentation, the objects it names, the paths it links to, the
   links and anchors, the test table and the version the README claims against the control file. The
   secrets are two separate CI jobs rather than a make target: gitleaks over the history and
   detect-secrets over the tree at HEAD. A gitleaks pre-commit hook also runs in the maintainer's
   checkout, which is where a secret is stopped before it is committed rather than before it is
   pushed; that hook is local and is not shipped in this repository, so a clone of it has the two CI
   jobs and not the hook. So a secret stops the commit locally and a broken anchor stops the
   pipeline, and neither depends on the other.
7. **Run the demonstrations**, `make demo` and `make scenarios`, and compare them against what the
   documentation claims. The scenario demos print the popular standard DBA query beside this
   extension's output, and the captured output is the proof that the two agree.
8. **Commit, push, wait for CI, tag, push the tag.** Push the commit before the tag, never in the
   same command: `git push --tags` in a command whose commit was rejected by a hook pushes a tag
   that points at the previous release, and that happened at 1.0.0.

   **Name the tag when you push it. Never `git push --tags`.**

   ```bash
   git push origin  v1.1.16          # the tag, by name, to Forgejo
   git push github v1.1.16          # and to GitHub
   ```

   `--tags` pushes **every** tag in the local repository, not the one you just made. This repository
   holds every tag it has ever made, and 16 of them are the `v0.*` releases, deliberately kept on
   Forgejo and never published: Forgejo is a private instance and is where the pre-1.0 history lives, while
   GitHub is the public face and carries `main` plus the release tags only. One `git push --tags` at
   the next release would publish all 16 to GitHub, and nothing in the output would look wrong.

   The tag is pushed to both remotes, so the public repository always has the release the gate
   checked. What it does not get is the 0.x history.

   Read the run before you tag:

   ```bash
   scripts/check-ci.sh          # refuses unless every workflow on HEAD is green
   ```

   This step exists because it was skipped and the result shipped. **1.1.11 could not be
   `make install`ed on any PostgreSQL version**, and CI caught that on the tag push: the
   `install-path checks` job went red with the same `install: will not overwrite just-created` error
   that was later found by hand. The run was never read, because nothing in this repository read it.
   `scripts/check-ci.sh` reads it, and fails closed: an unreachable API, a missing token, a commit
   not yet on the remote, a run still in progress, or a workflow reporting success while missing
   the job that does the gating are all refusals, not passes. A green run whose `install-path
   checks` job has been renamed is the failure mode worth designing against, because from the
   outside it looks exactly like success.

   **Tag only once this passes.** The check is fast and read-only; the tag is not.
9. **Never amend a pushed tag.** If a tag is wrong, delete it, push the deletion, and tag again, and
   say so in the changelog with the `git fetch --tags --force` that anyone who already fetched the
   bad tag needs.
10. **Record what could not be verified.** A claim that was taken from someone else's testing is
   written as such, in the same words, until someone has run it. That has already happened once at
   1.0.1 for the deadlock log line, and the changelog records both the original claim and how it was
   finally checked.