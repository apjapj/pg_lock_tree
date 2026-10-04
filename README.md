# pg_lock_tree

Readable lock-wait trees for PostgreSQL 14 and later.

When a database "hangs", it is usually one session at the front of a lock queue with everything
else waiting politely behind it. This extension shows that queue as a tree, names the root
blocker, and tells you what to run.

Pure SQL. No C, no background worker, no `shared_preload_libraries`, no restart.

| | |
|---|---|
| Current release | **v0.3** (tagged, green on PG 14 to 19beta4) |
| Requires | PostgreSQL 14+, a superuser for `CREATE EXTENSION` |
| Licence | PostgreSQL |

New here, start with **[INSTALL.md](INSTALL.md)**.

- **[INSTALL.md](INSTALL.md)**: install, grants, update, uninstall, troubleshooting
- **[CHANGELOG.md](CHANGELOG.md)**: what changed in each release
- **[scenarios/](scenarios/)**: seven incidents, compared against the usual hand-written query
- **[test/](test/)**: 73 pgTAP tests, and what each one pins down

## Quick start

```bash
git clone <your-forgejo>/apjapj/pg_lock_tree.git && cd pg_lock_tree
sudo make install                                     # copies the .sql and .control into place
sudo -u postgres psql -c 'CREATE EXTENSION pg_lock_tree;'
./scripts/check-install.sh                            # confirm it landed
```

On a multi-version box, name the version you mean. `pg_config` resolves to whichever comes
first on your `PATH`, and PostgreSQL will not warn you if you got it wrong:

```bash
sudo make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install
```

For a monitoring role, two grants are needed. `pg_read_all_stats` on its own is not enough:

```sql
CREATE ROLE monitoring LOGIN PASSWORD '...';   -- LOGIN only if something connects over TCP

GRANT pg_read_all_stats TO monitoring;         -- may see other sessions' rows and query text
GRANT SELECT ON lock_tree TO monitoring;       -- may read the view at all
```

Without the second one every query fails with `permission denied for view lock_tree`. See
[Grants](INSTALL.md#grants).

## What it looks like

A nightly batch holds a row lock and goes idle in its transaction. An `ALTER TABLE` queues behind
it, and ordinary reads queue behind the `ALTER`:

```
postgres=# SELECT * FROM lock_tree_text();
 166  idle in transaction  0s  nightly_batch  UPDATE ledger SET amount = amount WHERE id = 1
 └─167  0s  for AccessExclusiveLock on ledger  relation  ALTER TABLE ledger ADD COLUMN note text
   └─168  0s  for AccessShareLock on ledger  relation  SELECT sum(amount) FROM ledger WHERE id = 42
   └─169  0s  for AccessShareLock on ledger  relation  SELECT * FROM ledger ORDER BY id LIMIT 10

postgres=# SELECT root_pid, application_name, blocked_sessions FROM lock_tree_roots();
 root_pid | application_name | blocked_sessions
----------+------------------+------------------
      166 | nightly_batch    |                4

postgres=# SELECT * FROM lock_tree_actions();
-- 1 root blocker(s). Most sessions unblocked first.
-- 1. nightly_batch: idle in transaction, blocks 4 session(s), chain depth 2, longest wait 0s
-- Descriptions, not commands. Every line here is a comment. For statements you can run: SELECT command FROM lock_tree_command().
-- Terminating a session rolls back its transaction. Re-run the tree afterwards.

postgres=# SELECT command FROM lock_tree_command();
                 command
---------------------------------------
 SELECT pg_terminate_backend(166);
```

The three reads sit under the `ALTER TABLE`, not under the batch. A flat `pg_stat_activity`
listing, or a hand-pasted recursive query, shows five blocked sessions and no structure. This
shows one culprit and four symptoms, then hands you the command.

### Reading it, then running it

Those last two functions are separate on purpose, because they answer different questions and
0.2 tried to do both in one block and got it wrong in both directions. It printed
`pg_terminate_backend(166);` inside a SQL comment, so pasting that line did nothing at all and
still exited 0, while pasting only the fragment was a syntax error. A trailing semicolon
announcing a command that was inert.

- **`lock_tree_actions()`** describes. Prose only, no semicolons, every line a comment. It is
  for reading, and `SET lock_tree.actions = off` turns it off entirely if you would rather have
  the roots as the columns they already are in `lock_tree_roots()`.
- **`lock_tree_command()`** runs. One complete statement per row and nothing else, so it pastes
  cleanly, or runs all at once with psql's `\gexec`:

  ```sql
  SELECT command FROM lock_tree_command() \gexec
  ```

It always gives you the least destructive step that can work: `pg_terminate_backend()` for an
idle-in-transaction blocker, since cancelling one cannot achieve anything, and
`pg_cancel_backend()` for anything else, leaving the decision to escalate to a terminate with you.

Two kinds of root produce no statement at all, and both are explained by `lock_tree_roots()`:
a prepared transaction, which has no backend to act on, and your own session. Neither gets a
command that cannot work or that would disconnect you mid-query.

On a quiet database the two halves do not look alike, which trips people up. `lock_tree_actions()`
still returns its one header line, so you get `-- 0 root blocker(s)`; `lock_tree_command()`
returns no rows at all. That is deliberate: the description answers "is anything blocked", and a
header saying zero is a useful answer to that. The command function has nothing to say and no
heading to say it with.

## Objects

| Object | Use |
|---|---|
| `lock_tree` (view) | Every session in a blocking chain: `root_pid`, `depth` (0 is the root), `path`, `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age`, `query`, plus user, database, application and client. Ordered root first. |
| `lock_tree_roots()` | One row per root blocker, most sessions blocked first, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`. |
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. Full unabbreviated names. |
| `lock_tree_text_short(query_width int DEFAULT 100)` | The same tree with abbreviated modes and states, for when the queue is wide. Measured 17% narrower on a 61-session incident. |
| `lock_tree_actions()` | A written description of each root blocker and its blast radius, ordered by how many sessions each unblocks. Prose only, no runnable statements. `SET lock_tree.actions = off` suppresses it. |
| `lock_tree_command()` | One complete, runnable statement per root blocker, for pasting or for `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can work. |
| `lock_tree_age(interval)` | Compact interval rendering: `4s`, `1m30s`, `2h05m`. |
| `lock_tree_mode_short(text)`, `lock_tree_state_short(text)` | `AccessExclusiveLock` becomes `AX`, `idle in transaction` becomes `idle-in-tx`. Unknown values pass through unchanged rather than being guessed at. |

The view's columns and values are always full and unabbreviated. Shortening is opt-in, in the
text functions only, so anything selecting from the view or grepping for `AccessExclusiveLock`
keeps working.

## Behaviour worth knowing

- **Cost.** `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls
  it only for sessions already waiting on a heavyweight lock. Query it on demand or every few
  seconds, never in a tight loop.
- **Several blockers.** A waiter can be blocked by a lock holder *and* by requests queued ahead of
  it. `blocked_by` lists all of them, and the tree places the session on its deepest chain, so
  the queue order reads top to bottom.
- **Prepared transactions** appear as a root with pid `0` and the state
  `prepared transaction (see pg_prepared_xacts)`. This is the case a relation-based query cannot
  see at all, because a prepared transaction has no backend and no `pg_locks.pid`.
- **Deadlocks.** A wait-for cycle has no head of the queue, so there is nothing to point at as
  "the root". Every session in the cycle is reported as its own depth-0 root, `blocked_by` shows
  who each one is actually stuck behind, and `lock_tree_roots()` offers a cancel for each.
  PostgreSQL normally resolves a deadlock on its own after `deadlock_timeout` (1s by default), so
  the window is short unless that setting has been raised.
- **Snapshot.** `pg_stat_activity` and `pg_locks` are read separately, so a chain that changes
  mid-query can show a session as `exited`. Re-run the query.
- **Other databases.** Relations locked in a different database are shown by OID, because names
  only resolve in the current database.
- **Root actions.** A suggestion is a starting point, not a decision. Terminating a session
  rolls back its transaction.
- **It reports lock waits only.** A session that is running but slow, or waiting on IO or a
  network, is not in the tree. Check `pg_stat_activity.wait_event_type` for those.

## Seeing it work

```bash
psql -X -f demo.sql      # superuser; needs the dblink contrib module
```

`demo.sql` rebuilds the incident from the introduction with `dblink`, walks through the tree, the
roots and the action block, terminates the culprit and shows the queue drain. It finishes with a
two-session deadlock. Everything it creates is cleaned up, so it is safe to re-run.

For when something is already stuck and you want the answer now:

```sql
SELECT * FROM lock_tree_text();
SELECT root_pid, application_name, blocked_sessions, suggested_action FROM lock_tree_roots();
```

Match on `application_name`, not on pid. A pid identifies one session for as long as that
session lives, so it is the wrong key for correlating across restarts or reconnects.

## Compared with the usual query

The query most people paste is the recursive `pg_blocking_pids()` CTE that circulates as a wiki
entry and in a dozen blog posts. It is competent, and on plain coverage it finds the same
sessions this extension does. `scenarios/` builds seven incidents and runs both:

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

Where they actually differ:

- **A prepared transaction is invisible to it** (`s7`). The blocker has no `pg_locks.pid`, so the
  waiters come back with no blocker at all. This extension attributes them to pid 0 and names
  the state.
- **Run verbatim, it times out** (`s1`, `s4`). It omits `blocking_locks.granted`, so every
  ungranted lock joins with every other lock of the same identity, blockers included. Each
  recursion level multiplies that and the row count grows geometrically with chain depth. Five
  blocked sessions is enough. The suite compares against the version with that one line added,
  which is where people converge after their first incident.
- **A two-session deadlock costs it 40 rows** (`s6`). It has no cycle guard, so it walks the loop
  until a depth cap stops it, reporting the same pid pair at depths 1 to 20 in both directions.

Everything else this extension adds on top: roots named by `application_name`, the blast radius
per root, a ready-made command, and rendering that survives a wide queue.

Full write-up, including the reasoning behind the coverage metric, in
[scenarios/README.md](scenarios/README.md).

## Development

```bash
make prove              # 73 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all seven scenarios, both tools, output captured
make lint-docs          # the docs still match the code

scripts/matrix.sh       # install + CREATE EXTENSION + tests on PG 14 to 19 in the docker matrix
```

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

CI runs the same suite on all six versions. The last two files each need a server setting the
matrix images provide (`max_prepared_transactions`, `shared_preload_libraries=pg_cron`) and skip
themselves where it is absent, rather than failing a build that was never going to work. Neither
is a runtime requirement: `pg_lock_tree` itself needs no `shared_preload_libraries`.

## Roadmap

- **Next**: `lock_tree_history`, so an incident can be inspected after it has cleared. The hard
  part is now settled rather than assumed: `test/06_cron.sql` proves a `pg_cron` job can read
  `lock_tree`, land the result somewhere durable, and have it outlive the incident. What remains is
  the part that is a policy question, not a technical one: retention, and whether to `NOTIFY` when
  a chain passes a depth or age threshold.
- **Later**: show what each root *holds* that its waiters want, not only what the waiters ask for.
- **Untested**: loading through AWS `pg_tle` on RDS and Aurora, where `make install` is not
  possible. Being pure SQL is what makes it plausible. The thing most likely to fail is whether
  `pg_blocking_pids()` is reachable under `pg_tle`, so that is what to check first.