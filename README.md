# pg_lock_tree

Readable lock-wait trees for PostgreSQL 14 and later.

When a database "hangs", it is usually one session at the front of a lock queue with everything
else waiting politely behind it. This extension shows that queue as a tree, names the root
blocker, and tells you what to run.

Pure SQL. No C, no background worker, no `shared_preload_libraries`, no restart.

| | |
|---|---|
| Current release | **v1.0.1** (green on PG 14 to 19beta4) |
| Requires | PostgreSQL 14+, a superuser for `CREATE EXTENSION` |
| Licence | PostgreSQL |

## Where to go

Split by when you arrive, not by feature. Four moments, and the case that comes up first in each:

| You are | You have | Start at |
|---|---|---|
| On call, mid-incident, right now | a minute | **[The incident card](#the-incident-card)** below |
| On call, and the queue is too wide to read | a minute | [docs/incident.md](docs/incident.md) |
| Setting it up | an hour | **[INSTALL.md](INSTALL.md)**, then [docs/history.md](docs/history.md) and [docs/alerting.md](docs/alerting.md) |
| After the incident, with an afternoon | an afternoon | [docs/after-the-incident.md](docs/after-the-incident.md) |
| Looking up one function or column | a moment | [docs/reference.md](docs/reference.md) |
| Maintaining it, or curious why | longer | [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/design-notes.md](docs/design-notes.md) |
| Wondering what is planned | a moment | [docs/roadmap.md](docs/roadmap.md) |

## The incident card

Three commands. Copy the block.

```sql
-- 1. What is the tree, and who is at the root of it?
SELECT * FROM lock_tree_text();

-- 2. Who is blocking the most sessions?
SELECT * FROM lock_tree_roots();

-- 3. I have decided who to terminate. Show me the command, do not run it for me.
SELECT command FROM lock_tree_command() \gexec
```

If the queue is wider than fits on a screen, `lock_tree_wide()` and `lock_tree_summary()` summarise
it instead: [docs/incident.md](docs/incident.md).

If a root has no backend at all, it is a prepared transaction and `pg_terminate_backend` will not
reach it: [docs/incident.md](docs/incident.md#a-blocker-with-no-backend).

**Alerts.** `lock_tree_notify()` raises a NOTIFY when a root becomes worth waking someone for, and
`lock_tree_notify_resolved()` when it stops being worth it, so an alert has an end and not only a
start. If your pager is already wired to the channel, you have been told about this before you got
here. [docs/alerting.md](docs/alerting.md).

**History.** `lock_tree_sample()` on a schedule, and the tree becomes something you can look back
at: which statement held the queue up, and for how long.
[docs/history.md](docs/history.md).

## Quick start

```bash
sudo make install                     # needs postgresql-server-dev-NN and a superuser shell
sudo -u postgres psql -c 'CREATE EXTENSION pg_lock_tree;'
make check-install                    # prove the installation, on your own server
make demo                             # the scripted incident, start to finish
```

Then, in the database, when something is slow:

```sql
SELECT * FROM lock_tree_text();
```

## What it looks like

```
postgres=# SELECT * FROM lock_tree_text();
 166  idle in transaction  0s  nightly_batch  UPDATE ledger SET amount = amount WHERE id = 1
 └─167  0s  for AccessExclusiveLock on ledger  relation  ALTER TABLE ledger ADD COLUMN note text
   └─168  0s  for AccessShareLock on ledger  relation  SELECT sum(amount) FROM ledger WHERE id = 42
   └─169  0s  for AccessShareLock on ledger  relation  SELECT * FROM ledger ORDER BY id LIMIT 10
```

One root, `166`, a nightly job that has been `idle in transaction` since its UPDATE, with three
sessions behind it: an `ALTER TABLE` and two reads. Nothing here is a guess, and nothing here needs
`log_min_duration_statement` turned on.

### Reading it, then running it

Nothing in the tree is a suggestion to act. Get from "I can see it" to "I have decided":

```
postgres=# SELECT root_pid, application_name, blocked_sessions FROM lock_tree_roots();
 root_pid | application_name | blocked_sessions
----------+------------------+------------------
      166 | nightly_batch    |                3

postgres=# SELECT * FROM lock_tree_actions();
-- 1 root blocker(s). Most sessions unblocked first.
-- 1. nightly_batch: idle in transaction, blocks 3 session(s), chain depth 2, longest wait 0s
-- Descriptions, not commands. Every line here is a comment. For statements you can run: SELECT command FROM lock_tree_command().
-- Terminating a session rolls back its transaction. Re-run the tree afterwards.

postgres=# SELECT command FROM lock_tree_command();
                 command
---------------------------------------
 SELECT pg_terminate_backend(166);
```

`lock_tree_command()` returns SQL rather than running it, so nothing terminates a session because
you read a table. When you do run it, the blocker is rolled back rather than committed, and the
queue drains.

More, in [docs/incident.md](docs/incident.md): a queue that will not fit on a screen, and a root with
no backend. A deadlock that is happening now is in
[docs/after-the-incident.md](docs/after-the-incident.md#deadlocks).

## Seeing it work

The eight scenarios in [scenarios/](scenarios/) each build a real chain, sample it, and print the
tree next to the usual hand-written query, so you can see what the extra gives you:

```bash
make scenarios        # all eight, both tools, output captured
```

## Compared with the usual query

`pg_blocking_pids()` gives you the pids ahead of you and nothing else. The usual query joins that
to `pg_stat_activity` by hand, gets the waiters right, and stops there: no root, no depth, no
path, and no indication of which session to act on.

This extension is that join, plus the three things that make it usable mid-incident: the root is
named, the tree shows the shape of the queue rather than a flat list, and a command is offered
rather than implied. The scenarios print both side by side; the comparison is written up in
[scenarios/README.md](scenarios/README.md), and the short version is that the hand-written query
answers "who is ahead of me" and this answers "who do I terminate".

## Documentation

- **[INSTALL.md](INSTALL.md)**: requirements, install, grants, verify, update, uninstall, backups, troubleshooting
- **[docs/incident.md](docs/incident.md)**: a queue too wide to read, which query and which application are costing the most, a root with no backend, behaviour worth knowing
- **[docs/alerting.md](docs/alerting.md)**: thresholds, what escalates, scheduling, payloads, cleared events, what to do when one arrives, checking it works
- **[docs/history.md](docs/history.md)**: the sample, the scheduling hazard, redaction, sizing, pruning, and where backups stand
- **[docs/after-the-incident.md](docs/after-the-incident.md)**: why the tree is empty afterwards, replay, incidents, the deadlock report
- **[docs/reference.md](docs/reference.md)**: every object, the stability statement, settings, NOTIFY payload keys
- **[docs/design-notes.md](docs/design-notes.md)**: an index of every design argument and where it is made, plus the three that had no page to live on
- **[CONTRIBUTING.md](CONTRIBUTING.md)**: make targets, the tests, the matrix, the release checklist
- **[CHANGELOG.md](CHANGELOG.md)**: what changed in each release
- **[scenarios/](scenarios/)**: eight incidents, compared against the usual hand-written query
