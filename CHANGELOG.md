# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.2'`
selects a release.

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