# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.1'`
selects a release.

## 0.1 — 2026-10-03

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
- 31 pgTAP tests across four files, run against PG 14–19 by `scripts/matrix.sh` and CI.

### Fixed since the first draft

- **A wait-for cycle no longer empties the tree.** Root finding required a blocker that was
  not itself blocked. In a deadlock every session in the cycle is blocked, so the component
  matched nothing and `lock_tree` returned no rows — precisely when an operator most wants
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