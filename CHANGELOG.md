# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.3'`
selects a release.

## 0.4 (2026-10-04)

Adds history. Everything from 0.3 is unchanged: the view's columns and every function's
signature and output are byte-identical, and the update path is purely additive, so there is
nothing to migrate. `ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in
place; verified from clean 0.2 and 0.3 installs, and PostgreSQL chains `0.2--0.3--0.4` for you.

The motivation is the one limit nothing here could work around. Every other object reports the
present, which is exactly what you cannot read at the moment an incident is noticed: by then
`pg_stat_activity` has moved on and the tree is empty. History is opt-in and starts empty.

### Added

- `lock_tree_history`, a table of sampled trees, one row per session per sample so the shape of
  the chain survives. Indexed on `sampled_at` and on `(pid, sampled_at DESC)`, since an unindexed
  history table is one nobody can afford to query once it holds a day of samples.
- `lock_tree_sample()`: takes one snapshot, returns the number of rows written. **0** when
  nothing is blocked, rather than a row recording that nothing was blocked, so an idle server
  costs one `SELECT` and no storage.
- `lock_tree_incidents(max_gap interval DEFAULT '5 minutes')`: the history grouped into
  incidents, each with when it ran, peak sessions blocked, deepest chain, longest wait, and the
  root pids and application names involved. `peak_sessions` is a high-water mark, not a sum: a
  session seen at four samples was not four sessions.
- `lock_tree_prune(older_than interval)`: deletes history older than the given age and returns
  how many. The table only ever grows, one row per blocked session per sample, so this is not
  optional in practice.
- `test/07_history.sql`, 24 assertions: the sample, the rows outliving the incident, the
  segmentation at two thresholds, and pruning at both extremes. It calls `lock_tree_sample()`
  directly rather than scheduling it, so the history logic is tested without depending on
  `pg_cron`. What it does not re-test is whether a scheduler can reach any of it, which
  `test/06_cron.sql` already covers.

### Notes

- `lock_tree_sample()` is `SECURITY DEFINER` so the scheduled job's role needs no `INSERT`
  grant. It takes no arguments and inserts a fixed column list, so there is nothing to steer.
- `sampled_at` is `statement_timestamp()`, which took two attempts to get right and is worth
  recording. `clock_timestamp()` is volatile, so it is evaluated once per **row**: the sessions
  of one sample land microseconds apart, grouping by `sampled_at` yields one group per session
  instead of one per sample, and `peak_sessions` silently becomes 1 in every incident ever
  recorded. `now()` fails the other way, being the transaction timestamp, collapsing everything
  written in one transaction to a single instant. `statement_timestamp()` is stable for the one
  statement that takes the sample and moves between samples.
- Because `lock_tree_sample()` pins `search_path` to `pg_catalog`, a relation name in the history
  can be schema-qualified where the same relation read from your session is not: `regclass`
  renders with or without the schema depending on whether the schema is visible. Pinning is the
  safe choice and the qualification is the better of the two for a record that outlives the
  session which created it, but it is worth knowing before grepping history for a bare table
  name.
- Pruning uses `DELETE`, not `TRUNCATE`, since `TRUNCATE` would take rows you meant to keep.
- `pg_cron` remains a convenience, not a requirement. Any scheduler works, including a host cron
  job calling `psql`, and the extension still needs no `shared_preload_libraries`.

### Fixed

Four bugs, all in the new test file and all found by running it rather than reading it:

- The fixture inserted one row per timestamp, so every sample looked like a single session and
  `peak_sessions` read 1 throughout. Each sample now carries all three depths at one instant,
  which is the point: rows sharing an instant are one observation of one tree.
- Both prune calls ran in one quiet block before the assertion that the rows had survived, so
  "the rows are still there" was checked against an already-emptied table.
- The pruning window was one second, which removed the 13 backdated rows but not the 2 written
  seconds earlier by the live sample. The window has to be older than the newest row, and the
  newest row is always the one just taken, so it is now zero seconds.
- The cleanup terminated pids unconditionally, warning `PID N is not a PostgreSQL backend
  process` twice per run for a session already terminated deliberately. Harmless, and not worth
  leaving: two warnings per run teaches people to ignore warnings, and then a real one goes
  unnoticed.
- `scripts/lint-docs.sh` failed on `lock_tree_history`, because it only looked for `FUNCTION`
  and `VIEW` definitions when checking that a documented object exists. A table is as much a
  documented object as a function. Found by running the linter, which is what it is for.

Verified: 97 tests green on PG 14, 15, 16, 17, 18 and 19beta4 from the registry images; the
0.3 -> 0.4 and 0.2 -> 0.3 -> 0.4 update paths; demo, all seven scenarios and check-install.

## 0.3 (2026-10-04)

The action block, split in two, and two bugs found while checking it. The `lock_tree` view is
untouched: same columns, same values, same semantics, still full and unabbreviated, so anything
selecting from it or grepping for `AccessExclusiveLock` keeps working.
`ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in place; verified from a
clean 0.2 install.

### Fixed

- **A prepared transaction was given advice that could not work.** `lock_tree_roots()` returned
  the generic `pg_cancel_backend(0)` for the pid-0 root, but pid 0 is not a backend:
  `SELECT pg_cancel_backend(0)` returns false and warns `PID 0 is not a PostgreSQL backend
  process`. This was the one case where the queue is genuinely stuck and the operator has no
  other signal, so it is the worst possible place to hand back a no-op. It now says
  `ROLLBACK PREPARED`, and points at `pg_prepared_xacts` for the gid, which this extension
  cannot see. `scenarios/s7_prepared.sql` now exercises the action block, which it previously
  did not, which is why this survived 0.1 and 0.2.
- **`lock_tree_actions()` promised a copy-and-paste command and was not one.** Every line began
  with `--`, so pasting one did nothing at all and still exited 0; extracting just the fragment
  gave `syntax error at or near "pg_terminate_backend"`, since a bare call is not a statement.
  The trailing `;` announced runnability on a line that was inert.
- **`lock_tree_command()` never suggests terminating the session asking the question.** A
  monitoring session can itself be a root blocker; `root_pid <> pg_backend_pid()` now guards it.

### Added

- `lock_tree_command()`: one complete, runnable statement per root blocker, in one column and
  nothing else, so it pastes cleanly, `\copy`s cleanly, or runs all at once with psql's
  `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can
  work: `pg_terminate_backend()` for an idle-in-transaction blocker, since cancelling one could
  not achieve anything, and `pg_cancel_backend()` for anything else, leaving escalation to a
  terminate as the operator's decision. Prepared transactions and your own session produce no
  row, and `lock_tree_roots()` explains both.
- `test/06_cron.sql`: builds a live three-session chain and samples it with a `pg_cron` job,
  asserting the sampled rows outlive the incident. This is the feasibility check for scheduled
  history, not history itself: no retention policy, no threshold alerting. It skips itself
  where `pg_cron` is absent rather than failing.

### Changed

- `lock_tree_actions()` keeps its signature but now returns prose: no runnable statements, no
  semicolons, every line a comment, and a line pointing at `lock_tree_command()`. **This is a
  breaking change for anything parsing its output**, deliberately: the old text claimed to be
  executable and was not.
- `SET lock_tree.actions = off` suppresses `lock_tree_actions()` entirely, for anyone who would
  rather read the roots as the columns `lock_tree_roots()` already gives them. A pure-SQL
  extension can read and test a placeholder GUC without declaring it; `off`, `false`, `no` and
  `0` all switch it off.
- The version guard now says what a backport would cost rather than just refusing. On 13 and
  earlier the extension refuses to install, and the error states that `pg_locks.waitstart` is the
  only blocker and that everything else works on 9.6+. Verified by patching out the three
  `waitstart` references and running the real thing on 13: the tree, roots, depths, paths and
  `blocked_by` were all correct, with only wait age empty.
- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.3.sql`, and its note on why there is no
  `command:` override now covers `pg_cron` as well as `max_prepared_transactions`.
- `scripts/check-install.sh` verifies `lock_tree_command()` and `lock_tree_lines()` exist and
  are callable, and reports whether `pg_cron` is preloaded, so a skip in `test/06_cron.sql` is
  explained rather than mysterious.
- `scripts/lint-docs.sh` (`make lint-docs`, `make check`) and `.forgejo/workflows/lint.yml`:
  checks the documentation's factual claims against the code, since docs rot silently and
  nothing else would notice. Version agreement across `pg_lock_tree.control`, `README.md` and
  `CHANGELOG.md`; every object the docs name is defined in the release SQL; every SQL file is
  installed by the Makefile; every file and test the docs link to exists; each test's `plan()`
  matches its assertions and each `skip()` agrees with its plan; no em-dashes or en-dashes.
  Needs no database, so it runs as its own CI job rather than inside the test matrix.

### Not changed

`pg_lock_tree` still needs no `shared_preload_libraries`. `pg_cron` is a dependency of the test
harness, preloaded in the `pg-test` images so `test/06_cron.sql` has something to schedule. The
other five test files run and pass without it.

## 0.2 (2026-10-04)

Rendering and ergonomics only. The `lock_tree` view's columns, values and semantics are
unchanged and still carry full, unabbreviated names, so anything selecting from the view or
grepping for `AccessExclusiveLock` keeps working. `ALTER EXTENSION pg_lock_tree UPDATE` moves an
existing installation in place; verified from a clean 0.1 install.

### Added

- `lock_tree_text_short(query_width int DEFAULT 100)`: the same tree with abbreviated lock
  modes and session states. Measured at **17% narrower** on a 61-session incident, and the
  default query width is larger precisely because the abbreviations gave the room back.
- `lock_tree_actions()`: one command per root blocker, ordered by how many sessions each
  unblocks, each carrying its blast radius (`blocks N session(s), chain depth D`) on the same
  line. **Deliberately separate from the tree:** with a hundred sessions stuck the tree is
  already a wall of text, and a command on every line would double it. Superseded in **0.3**,
  which found the command was not actually pasteable; see the 0.3 entry.
- `lock_tree_age(interval)`: `4s`, `1m30s`, `2h05m`. Applies to both text forms.
- `lock_tree_mode_short(text)`, `lock_tree_state_short(text)`: `AX`, `idle-in-tx`. Values not
  in the tables pass through unchanged rather than being guessed at.
- `scenarios/`: seven incidents built with `dblink`, each queried both by this extension and
  by the published recursive CTE, with both outputs captured.
- `test/05_formatting.sql`: pins the exact output of the helpers above, since the scenario
  suite derives its width measurements from them.

### Changed

- `lock_tree_text()` output layout. The root line is now `pid  state  age  app  query` rather
  than `pid  [state, xact age]  app (user@db)  query`; waiter lines carry a compact wait age and
  the lock mode without the word "for". Same signature, same defaults, and the per-line
  suggestion moved out to `lock_tree_actions()`.
- `Makefile` now installs update scripts. Listing `pg_lock_tree--0.1--0.2.sql` in `DATA` does
  not work. PGXS copies `DATA` by name and an update path is found by a different convention, so
  so there is an explicit `install-upgrades` target.
- `.forgejo/workflows/test.yml` loads the then-current `pg_lock_tree--0.2.sql`.

### Scenario results

| scenario | waiting | published CTE | pg_lock_tree |
|---|---|---|---|
| 1 nightly batch | 4 | 4 | 4 |
| 2 three chains | 4 | 4 | 4 |
| 3 row locks | 2 | 2 | 2 |
| 4 wide queue | 60 | 60 | 60 |
| 5 advisory locks | 2 | 2 | 2 |
| 6 deadlock | 2 | 2 | 2 |
| 7 prepared transaction | 2 | **0** | 2 |

Coverage ties almost everywhere, and the suite reports that rather than overclaiming. The real
differences are that the published form times out when run verbatim (`s1`, `s4`), returns 40
rows for a 2-session deadlock (`s6`), and cannot see a blocker that has no `pg_locks.pid`
(`s7`).

## 0.1 (2026-10-03)

First release. Pure SQL, PostgreSQL 14+.

### Added

- `lock_tree` view: every session in a lock-wait chain, with `root_pid`, `depth`, `path`,
  `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age` and `query`.
- `lock_tree_roots()`: head-of-line blockers only, ordered by how many sessions each one
  blocks, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`.
- `lock_tree_text(query_width int DEFAULT 60)`: the tree as indented text for psql.
- A session blocked by several blockers is placed on its deepest chain, so the queue order
  reads top to bottom rather than fanning out.
- Prepared transactions appear as a root at pid `0`.
- Relations locked in another database are shown by OID, since names only resolve in the
  current database.
- 31 pgTAP tests across four files, run against PG 14 to 19 by `scripts/matrix.sh` and CI.

### Fixed since the first draft

- **A wait-for cycle no longer empties the tree.** Root finding required a blocker that was
  not itself blocked. In a deadlock every session in the cycle is blocked, so the component
  matched nothing and `lock_tree` returned no rows, precisely when an operator most wants
  output. The walk is now seeded from every blocker and each session in a rootless cycle is
  reported as its own depth-0 root. `test/03_deadlock.sql` builds a real two-session cycle
  and covers this.
- **The documented monitoring grants were incomplete.** `GRANT pg_read_all_stats` alone still
  failed with `permission denied for view lock_tree`; `GRANT SELECT ON lock_tree` is also
  required. `test/02_permissions.sql` pins both halves.

### Notes

- `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it
  only for sessions already waiting on a heavyweight lock. Sample every few seconds at most,
  never in a tight loop.
- Behaviour that needs `max_prepared_transactions > 0` (the prepared-transaction path) is
  covered by `test/04_prepared.sql`; the shared `pg-dev-infra` compose file sets it.