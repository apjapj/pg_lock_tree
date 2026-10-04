# pg_lock_tree

Current release: **v0.2**. (`v0.1` is the first release; `ALTER EXTENSION pg_lock_tree UPDATE` moves between them.)

Readable lock-wait trees for PostgreSQL 14+. When the database "hangs", it is usually one session at the front of a lock queue with everything else waiting politely behind it. This extension shows that queue as a tree, names the root blocker, and suggests what to do about it.

Pure SQL; no C, no background worker, no `shared_preload_libraries`.

PostgreSQL Licence. See [CHANGELOG.md](CHANGELOG.md) for what changed and
[test/](test/) for how the behaviour is pinned down.

## What it looks like

A nightly batch holds a row lock and idles in its transaction. An `ALTER TABLE` queues behind it, and ordinary reads queue behind the `ALTER`:

```
postgres=# SELECT * FROM lock_tree_text();
 2715  [idle in transaction, xact 00:00:03]  nightly_batch (postgres@postgres)  UPDATE ledger SET amount = amount WHERE id = 1
 └─ 2716  waits 00:00:03 for AccessExclusiveLock on ledger  ALTER TABLE ledger ADD COLUMN IF NOT EXISTS note text
    └─ 2717  waits 00:00:02 for AccessShareLock on ledger  SELECT sum(amount) FROM ledger WHERE id = 42
    └─ 2718  waits 00:00:02 for AccessShareLock on ledger  SELECT * FROM ledger ORDER BY id LIMIT 10

postgres=# SELECT root_pid, state, application_name, blocked_sessions, suggested_action FROM lock_tree_roots();
 root_pid |        state        | application_name | blocked_sessions |                        suggested_action
----------+---------------------+------------------+------------------+-----------------------------------------------------------------
     2715 | idle in transaction | nightly_batch    |                3 | Idle in an open transaction. SELECT pg_terminate_backend(2715);
```

## Objects

| Object | Use |
|---|---|
| `lock_tree` (view) | Every session in a blocking chain: `root_pid`, `depth` (0 = root), `path`, `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age`, `query`, plus user, database, application and client. Ordered root first. |
| `lock_tree_roots()` | One row per root blocker, most sessions blocked first, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`. |
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. Full unabbreviated names. |
| `lock_tree_text_short(query_width int DEFAULT 100)` | The same tree with abbreviated modes and states, for when the queue is wide. Measured 17% narrower on a 61-session incident. |
| `lock_tree_actions()` | One copy-and-paste command per root blocker, ordered by how many sessions each unblocks, with its blast radius on the same line. Kept separate from the tree on purpose. |
| `lock_tree_age(interval)` | Compact interval rendering: `4s`, `1m30s`, `2h05m`. |
| `lock_tree_mode_short(text)` / `lock_tree_state_short(text)` | `AccessExclusiveLock` → `AX`, `idle in transaction` → `idle-in-tx`. Unknown values pass through unchanged. |

## Install

```bash
make install                      # uses the pg_config on your PATH; override with PG_CONFIG=...
psql -c 'CREATE EXTENSION pg_lock_tree;'
```

To read the tree, a monitoring role needs **two** grants — `pg_read_all_stats` decides which
`pg_stat_activity` rows and query text it may see, but the role also needs `SELECT` on the view
itself, otherwise every query fails with `permission denied for view lock_tree`:

```sql
GRANT pg_read_all_stats TO monitoring;   -- see other users' queries
GRANT SELECT ON lock_tree TO monitoring; -- and be allowed to read the view at all
```

`lock_tree_roots()` and `lock_tree_text()` are executable by `PUBLIC` by default and become
readable once the view is.

## Behaviour worth knowing

- **Cost.** `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it only for sessions already waiting on a heavyweight lock. Query it on demand or every few seconds — never in a tight loop.
- **Several blockers.** A waiter can be blocked by a lock holder *and* by requests queued ahead of it. `blocked_by` lists all of them; the tree places the session on its deepest chain, so the queue order reads top to bottom.
- **Prepared transactions** appear as a root with pid `0` and the state `prepared transaction (see pg_prepared_xacts)`.
- **Deadlocks.** A wait-for cycle has no head of the queue, so there is nothing to point at as "the root". Every session in the cycle is reported as its own depth-0 root, and `lock_tree_roots()` lists all of them with a cancel suggestion. `blocked_by` shows who each one is actually stuck behind. Note that PostgreSQL normally resolves a deadlock on its own after `deadlock_timeout` (1s by default), so the window in which you can see this is short unless that setting has been raised.
- **Snapshot.** `pg_stat_activity` and `pg_locks` are read separately, so a chain that changes mid-query can show a session as `exited`. Re-run the query.
- **Other databases.** Relations locked in a different database are shown by OID, because names only resolve in the current database.
- **Root actions.** The suggestion is a starting point, not a decision. Terminating a session rolls back its transaction.

## Tests

52 pgTAP tests in five files. `test/01_lock_tree.sql` builds a real five-session chain with `dblink` (superuser needed) and checks roots, depth, paths, multiple blockers, wait details, the root summary, the text output, and that the tree empties when the root rolls back. `test/02_permissions.sql` pins the grants a monitoring role needs. `test/03_deadlock.sql` builds a real two-session wait-for cycle and checks the tree does not go empty. `test/04_prepared.sql` checks a prepared transaction shows up as root pid `0`. `test/05_formatting.sql` pins the exact output of the 0.2 rendering helpers.

```bash
make prove                        # against the server your libpq env vars point at
scripts/matrix.sh                 # make install + CREATE EXTENSION + tests on PG 14–19 in the docker test matrix
```

## Scenario suite

`scenarios/` builds seven incidents for real and queries each one two ways — by this extension
and by the published recursive `pg_blocking_pids()` CTE — capturing both so they can be
compared side by side.

```bash
make scenarios                      # all seven
./scenarios/run.sh s7               # just the interesting one
```

```
  scenario            waiting      std     tree   verdict
  s1_nightly_batch          4        4        4   tie
  s2_three_chains           4        4        4   tie
  s3_row_locks              2        2        2   tie
  s4_wide_queue            60       60       60   tie
  s5_mixed_locks            2        2        2   tie
  s6_deadlock               2        2        2   tie
  s7_prepared               2        0        2   pg_lock_tree +2
```

On plain coverage the two tie almost everywhere, and the suite says so rather than
overclaiming. What differs:

- **`s7_prepared` is the one that matters.** A prepared transaction has no backend and no
  `pg_locks.pid`. The published query finds **nothing** — its waiters appear with no blocker at
  all. This extension attributes them to pid 0 and names the state.
- **`s1`/`s4`: the published form times out.** Run verbatim it never returns; it omits
  `blocking_locks.granted`, so the row count grows geometrically with chain depth. The suite
  compares against the version with that one line added.
- **`s6`: 40 rows versus 2.** Both find the two deadlocked sessions, but the published
  recursion has no cycle guard and walks the loop to the depth cap.

See [`scenarios/README.md`](scenarios/README.md) for the full write-up and the reasoning
behind the coverage metric.

## Seeing it work

`demo.sql` rebuilds the nightly-batch incident from the introduction with `dblink`, then walks
through `lock_tree_text()`, `lock_tree`, `lock_tree_roots()` and back to an empty tree after you
terminate the culprit. It finishes with a two-session deadlock, to show a cycle that has no head
of the queue. Everything it creates is cleaned up, so it is safe to re-run.

```bash
psql -X -f demo.sql              # superuser; needs the dblink contrib module
```

The one-line version, for when something is already stuck and you want the answer now:

```sql
SELECT * FROM lock_tree_text();
SELECT root_pid, application_name, blocked_sessions, suggested_action FROM lock_tree_roots();
```

CI (`.forgejo/workflows/test.yml`) runs the same suite on all six versions by loading the SQL file directly.

## Roadmap

- **0.2** — `lock_tree_history` table sampled by `pg_cron`, so you can inspect an incident after it cleared; `NOTIFY` when a chain passes a depth or age threshold.
- **0.3** — Show what each root *holds* that its waiters want, not just what the waiters ask for.
- **Managed clouds** — being pure SQL, it should load through AWS's `pg_tle` (Trusted Language Extensions) where `make install` isn't possible. Untested.
