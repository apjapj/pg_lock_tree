# pg_lock_tree

Readable lock-wait trees for PostgreSQL 14 and later. 14 stays tested past its November 2026 end of life, until PostgreSQL 19 is stable.

When a database "hangs", it is usually one session at the front of a lock queue with everything
else waiting politely behind it. This extension shows that queue as a tree, names the root
blocker, and tells you what to run.

Pure SQL. No C, no background worker, no `shared_preload_libraries`, no restart.

| | |
|---|---|
| Current release | **v1.1.10** (green on PG 14 to 19beta4) |
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

Captured from a run of `make demo`, with pids and waits replaced by `<PID>` and `<AGE>`:

<!-- generated: docs/examples/demo-tree.md#tree -->

```
<PID>  idle in transaction  <AGE>  nightly_batch  UPDATE demo_ledger SET amount = amount WHERE id = 1
└─<PID>  <AGE>  for AccessExclusiveLock on demo_ledger  relation  ALTER TABLE demo_ledger ADD COLUMN note text
  └─<PID>  <AGE>  for AccessShareLock on demo_ledger  relation  SELECT sum(amount) FROM demo_ledger WHERE id = 1
  └─<PID>  <AGE>  for AccessShareLock on demo_ledger  relation  SELECT * FROM demo_ledger ORDER BY id LIMIT 10
  └─<PID>  <AGE>  for AccessShareLock on demo_ledger  relation  SELECT count(*) FROM demo_ledger
```

<!-- /generated -->

One root, a nightly job that has been `idle in transaction` since its UPDATE, with four sessions behind
it: an `ALTER TABLE`, then three reads that queue behind the `ALTER TABLE` rather than straight at the
batch. The reads carry different `application_name` values so the per-application figures further down
have something to separate. Nothing here is a guess, and nothing here needs
`log_min_duration_statement` turned on.

The pids and waits are the only things replaced: psql aligns its columns to the widest value in the
run, so the spacing is normalised to two spaces per column and the indentation, which is the depth, is
left alone. `make demo` builds this on a table it creates called `demo_ledger`, and drops it afterwards.

### Reading it, then running it

Nothing in the tree is a suggestion to act. Get from "I can see it" to "I have decided". Two functions,
captured from the same run as the tree above, and they are kept apart on purpose:

<!-- generated: docs/examples/demo-decision.md#actions -->

```
-- 1 root blocker(s). Most sessions unblocked first.
-- 1. nightly_batch: idle in transaction, blocks 4 session(s), chain depth 2, longest wait <AGE>
-- Descriptions, not commands. Every line here is a comment. For statements you can run: SELECT command FROM lock_tree_command().
-- Terminating a session rolls back its transaction. Re-run the tree afterwards.
```

<!-- /generated -->

Every line there is a comment, so pasting it does nothing. For something you can run:

<!-- generated: docs/examples/demo-decision.md#command -->

```
SELECT pg_terminate_backend(<PID>);
```

<!-- /generated -->

`lock_tree_command()` returns SQL rather than running it, so nothing terminates a session because
you read a table. When you do run it, the blocker is rolled back rather than committed, and the
queue drains.

More, in [docs/incident.md](docs/incident.md): a queue that will not fit on a screen, and a root with
no backend. A deadlock that is happening now is in
[docs/after-the-incident.md](docs/after-the-incident.md#deadlocks).

## Seeing it work

```bash
make demo             # one incident, start to end. empties lock_tree_history: use a scratch database
make scenarios        # eight incidents, each queried two ways, output captured
```

The demo builds a real chain with dblink, waits for the lock queue to form, prints it four ways, and
cleans up after itself. This is the order it prints, captured from a run rather than described:

<!-- generated: docs/examples/demo-sections.md#sections -->

```
# 0. Install
# 1. A quiet database: the tree is empty
# 2. Build the incident
# 3. lock_tree_text(): the queue, top to bottom
# 4. lock_tree: who blocks whom, and for how long
# 5. lock_tree_roots(): the one session to act on
# 6. What the operator reads, and what they run
# 7. Bonus: a deadlock has no head of the queue
# 8. Bonus: what it looked like while you were not looking
# 9. Cleanup
```

<!-- /generated -->

The [full transcript](docs/examples/demo.out) is captured too, with pids, waits and timestamps
replaced by `<PID>`, `<AGE>` and `<TIMESTAMP>` so two runs differ nowhere. `make capture` writes both.

The eight scenarios in [scenarios/](scenarios/) are the harder version: each builds a real chain,
samples it, and prints the tree next to the usual hand-written query on the same data at the same
moment. Scenario 7 is the one to read, because it is the only case where the usual query reports
nothing at all. The numbers are in [scenarios/README.md](scenarios/README.md), and the coverage table
there is generated rather than written.

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
