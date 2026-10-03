# pg_lock_tree v0.1

Readable lock-wait trees for PostgreSQL 14+. When the database "hangs", it is usually one session at the front of a lock queue with everything else waiting politely behind it. This extension shows that queue as a tree, names the root blocker, and suggests what to do about it.

Pure SQL; no C, no background worker, no `shared_preload_libraries`.

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
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. |

## Install

```bash
make install                      # uses the pg_config on your PATH; override with PG_CONFIG=...
psql -c 'CREATE EXTENSION pg_lock_tree;'
```

To see other users' queries, the reading role needs `pg_read_all_stats` (or superuser):

```sql
GRANT pg_read_all_stats TO monitoring;
```

## Behaviour worth knowing

- **Cost.** `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it only for sessions already waiting on a heavyweight lock. Query it on demand or every few seconds — never in a tight loop.
- **Several blockers.** A waiter can be blocked by a lock holder *and* by requests queued ahead of it. `blocked_by` lists all of them; the tree places the session on its deepest chain, so the queue order reads top to bottom.
- **Prepared transactions** appear as a root with pid `0` and the state `prepared transaction (see pg_prepared_xacts)`.
- **Snapshot.** `pg_stat_activity` and `pg_locks` are read separately, so a chain that changes mid-query can show a session as `exited`. Re-run the query.
- **Other databases.** Relations locked in a different database are shown by OID, because names only resolve in the current database.
- **Root actions.** The suggestion is a starting point, not a decision. Terminating a session rolls back its transaction.

## Tests

19 pgTAP tests build a real five-session chain with `dblink` (superuser needed) and check roots, depth, paths, multiple blockers, wait details, the root summary, the text output, and that the tree empties when the root rolls back.

```bash
make prove                        # against the server your libpq env vars point at
scripts/matrix.sh                 # make install + CREATE EXTENSION + tests on PG 14–19 in the docker test matrix
```

CI (`.forgejo/workflows/test.yml`) runs the same suite on all six versions by loading the SQL file directly.

## Roadmap

- **0.2** — `lock_tree_history` table sampled by `pg_cron`, so you can inspect an incident after it cleared; `NOTIFY` when a chain passes a depth or age threshold.
- **0.3** — Show what each root *holds* that its waiters want, not just what the waiters ask for.
- **Managed clouds** — being pure SQL, it should load through AWS's `pg_tle` (Trusted Language Extensions) where `make install` isn't possible. Untested.
