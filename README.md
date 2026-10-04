# pg_lock_tree

Readable lock-wait trees for PostgreSQL 14 and later.

When a database "hangs", it is usually one session at the front of a lock queue with everything
else waiting politely behind it. This extension shows that queue as a tree, names the root
blocker, and tells you what to run.

Pure SQL. No C, no background worker, no `shared_preload_libraries`, no restart.

| | |
|---|---|
| Current release | **v0.9** (green on PG 14 to 19beta4) |
| Requires | PostgreSQL 14+, a superuser for `CREATE EXTENSION` |
| Licence | PostgreSQL |

New here, start with **[INSTALL.md](INSTALL.md)**.

- **[INSTALL.md](INSTALL.md)**: install, grants, update, uninstall, troubleshooting
- **[CHANGELOG.md](CHANGELOG.md)**: what changed in each release
- **[scenarios/](scenarios/)**: eight incidents, compared against the usual hand-written query
- **[test/](test/)**: 221 pgTAP tests, and what each one pins down

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

## Alerting

Everything above is for someone who is already looking. This is for when nobody is.

`lock_tree_notify()` raises a `NOTIFY` when a lock chain is bad enough to be worth waking
someone for. It does **not** page anyone, and understanding why is the first thing worth
understanding about it.

### What this does and does not do

It raises a `NOTIFY` on a PostgreSQL channel. That is all. Turning that channel into a page is
the deployment's job, and the reason is that paging is a policy decision: what pages you, where
it goes, who gets woken at 3am, and what happens when the pager is down are all choices that
belong to whoever runs the system. The payload is JSON so that whatever you connect can parse it
without knowing anything about this extension.

The usual way to connect it is `LISTEN` from a script, or a `LISTEN`/`NOTIFY` bridge shipped with
PostgreSQL that forwards to another channel. There is no opinion here about which.

### Why it does not notify on every sample

This is the design decision that matters, and getting it wrong makes alerting worse than not
having it.

If you call `lock_tree_notify()` on every sample and it notifies whenever anything is blocked,
then a two-minute incident with a ten-second sample produces twelve notifications. Everyone
learns within a week that the `lock_tree` channel is noise, and the one alert that mattered gets
filtered along with the rest. **A diagnostic tool that cries wolf is worse than a silent one**,
because it costs you the one thing the tool was for.

So the function keeps state in `lock_tree_alert` and notifies only on:

| | when it notifies |
|---|---|
| **Onset** | a root becomes notable and has not been notable before on this channel |
| **Escalation: wider** | a root already known is now blocking *more* sessions than it ever has |
| **Escalation: deeper** | it is *deeper* than it ever has |
| **Escalation: older** | its longest wait has *doubled* since the last notification |

and stays quiet while a chain sits at the same severity. A queue wobbling between 40 and 12
sessions notifies once, not twice a minute.

State is compared against high-water marks, not the previous sample, which is what makes
"escalation" and "recovery" distinguishable. A root dropping from 40 to 12 sessions is getting
better and must not re-notify.

When a root stops being notable its state is forgotten, so the same chain returning later alerts
again. That is what makes a *second* incident visible rather than suppressed as already-seen.

### Why the wait escalates by doubling and not by growing

Wider and deeper are **edges**: something happened, and the comparison says so. A wait is not an
edge, it is a slope. It grows every second, so asking "is the longest wait longer than last time?"
is true on every single sample, and the function would notify sixty times an hour. That is the
exact failure `lock_tree_alert` exists to prevent, reached by a different route.

So the age comparison is against **the wait recorded at the last notification**, and it fires only
once the wait has doubled. A chain that never gets wider or deeper, and simply ages, produces:

```
 30s    1m    2m    4m    8m    16m   32m
  |     |     |     |     |      |      |
  +-----+-----+-----+-----+------+------+
```

Seven notifications for a thirty-two minute incident, each one saying it is roughly twice as bad as
the last. Seven is the point: few enough that nobody learns to filter the channel, many enough
that a thirty-minute queue does not sit at the same reported severity for half an hour.

**Age escalation only applies when `min_wait` is set.** If you pass `min_wait => NULL` you have
said you do not want to be paged on wait age, and that switch is honoured even when the wait is
enormous. A second page about a slow queue you did not ask about is how a channel stops being read.

One detail that matters if you read the code: the doubling falls back to `min_wait` when no wait
has been recorded yet, because the view truncates `wait_age` to whole seconds and a wait under a
second reads as zero. Comparing against twice zero is true forever. That was a real bug, found by
the assertion that nothing is recorded when `min_wait` is off.

### Choosing thresholds

This is the part people get wrong, so the thresholds are arguments rather than settings and there
are no meaningful defaults. A default nobody reads is a default nobody trusts.

```sql
lock_tree_notify(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,        -- NULL or 0 switches this off
  min_depth    integer  DEFAULT 2,        -- NULL or 0 switches this off
  min_wait     interval DEFAULT '30 seconds'  -- NULL switches this off
) RETURNS bigint
```

**A root alerts if it meets AT LEAST ONE criterion that is switched on.** With all three at their
defaults, a chain alerts if it blocks one session, **or** is two deep, **or** has someone waiting
30 seconds.

That is deliberate. A queue can be bad in ways that have nothing to do with each other: a hundred
sessions waiting one second is not an incident, and two sessions waiting an hour is. An operator
paging on "deep **or** slow" will not miss the incident that is both, and an operator paging on
"deep **and** slow" will sit through both of the others.

At least one criterion must be on. All three off means "alert on every root", which is rejected
with an error rather than quietly given a plausible default.

What the defaults are *for*: they are a starting point for a database you have not watched yet,
and they will be wrong for any specific database within a week. The intended sequence is:

1. Leave the defaults and schedule it. Read what it reports.
2. Note which criteria actually fired. Most databases will only ever trip `min_depth`.
3. Set the other two to NULL and raise the one that matters.

```sql
-- only care about long waits, on a busy server where shallow queues are normal
SELECT lock_tree_notify('lock_tree', min_blocked => NULL, min_depth => NULL,
                        min_wait => interval '2 minutes');
```

`NULL` means "do not consider this". `0` is the same thing for the two integer criteria, since
"at least 0 sessions blocked" is every root.

### What the return value is for

It returns how many notifications it raised. **Zero is the normal, healthy result**, and it is the
value worth watching. A sampler that logs it will show you exactly when your alerting is doing
something:

```sql
SELECT now(), lock_tree_notify() AS alerts;
```

If that column is zero forever, either nothing is wrong or your thresholds are too high to ever
fire. Both are worth knowing, and neither is visible from a silent channel alone.

### Scheduling it

The natural home is the same cron entry as the sample, because both need to run on the same beat:

```sql
SELECT cron.schedule('lock_tree_sample', '10 seconds',
                     $$SELECT lock_tree_sample(); SELECT lock_tree_notify();$$);
```

One statement can do both, which also means the alert reflects the instant the sample was taken
rather than a slightly later one.

### The payload

```json
{"channel":"lock_tree","root_pid":179,"application_name":"nightly_reconciliation",
 "blocked_sessions":40,"max_depth":2,"longest_wait":"3m12s",
 "waiting_for":"AccessShareLock on ledger"}
```

Every key is always present, `null` excepted where there is genuinely nothing to say. The server
enforces an 8000-byte payload limit and this is far below it.

`application_name` is the one to key on rather than `root_pid`. A pid identifies one session for
as long as that session lives, which is the wrong key for correlating a page with a log or a
dashboard across restarts and reconnects.

### `lock_tree_alert`, and why you should not need to look at it

One row per notable root per channel per threshold set, holding the high-water marks. It is the
size of the current queue, not of its history, and `lock_tree_notify()` maintains it. You should
never need to touch it.

`lock_tree_prune_alerts()` exists for state orphaned by a restart or a retired channel name, and
is worth calling from the same cron entry as the sample if you care. It is not load-bearing.

### Checking it works

Two ways, and they check different things.

```bash
./scripts/check-alert.sh              # builds a chain, notifies, and reads the notification back
./scripts/check-alert.sh --explain    # the same, then explains the payload it received
./scripts/check-alert.sh --explain '{"root_pid":0,...}'
```

That verifies the delivery path end to end, which no assertion can: `psql` prints notifications to
stdout and a TAP test cannot see stdout, so the stream is checked by a real second client.

`test/11_alert.sql` verifies the decisions, which is the part worth unit-testing: onset fires once,
an unchanged chain stays silent, escalation fires on width and on depth, age escalates only on a
doubling, recovery then relapse fires again, thresholds behave, and all three disabled is an error.

### What to do when one arrives

`--explain` takes the payload and prints what it means, the queries to run in order, and what not
to do. It needs **no database**, which is the point: the first thing you do at 3am should be
something that cannot fail because the database is the thing that is broken.

```
$ ./scripts/check-alert.sh --explain '{"root_pid":0,
    "root_object":"AccessExclusiveLock on public.ledger","application_name":"",
    "blocked_sessions":12,"max_depth":1,"longest_wait":"9m05s",
    "waiting_for":"AccessShareLock on public.ledger"}'

  What it means
  -------------
  The blocker is a PREPARED TRANSACTION. It has no backend, no session and no
  application_name, which is why the root pid is 0 and the name is empty.
  Nothing you can do to a session will clear this. pg_cancel_backend(0) returns
  false and warns that pid 0 is not a backend; pg_terminate_backend(0) likewise.
  The only remedy is ROLLBACK PREPARED, and you need the gid.

  Run these, in this order
  ------------------------
  SELECT gid, prepared, owner FROM pg_prepared_xacts;
    -- pick the gid whose prepared time is close to the incident, then:
  ROLLBACK PREPARED '<gid>';
  -- the lock it holds is: AccessExclusiveLock on public.ledger
```

It branches on `root_pid` rather than on the message text, so a session root gets
`pg_terminate_backend` steps and a prepared root gets `ROLLBACK PREPARED` steps. That branch is
worth being careful about: the two failures look identical on a dashboard and need opposite
remedies.

`make explain-alert PAYLOAD='…'` is the same thing if you prefer make. A payload that is not JSON,
or is JSON from something else on the same channel, is reported as such rather than guessed at.

### Choosing an interval

`lock_tree_sampling_advice()` answers "how often should I be sampling", which is a question about
cost rather than taste. The cost of a sample is one row per blocked session, so a wide queue
argues for a wider interval:

```sql
SELECT * FROM lock_tree_sampling_advice();
```

```
 blocked_sessions | roots | suggested_every |                        reason
------------------+-------+-----------------+-------------------------------------------------
                0 |     0 | 00:00:05        | nothing is blocked: the table stays empty at any
                 |       |                 | interval, so sample rarely
               12 |     2 | 00:00:10        | a busy queue: 10 seconds catches anything that
                 |       |                 | lasts, at a tenth the storage
              450 |     9 | 00:00:30        | a wide queue: each sample writes a row per blocked
                 |       |                 | session, so widen the interval
```

### Requirements, plainly

- **`NOTIFY` needs nothing.** No extension, no `shared_preload_libraries`, no restart. If
  `lock_tree_notify()` works at all, `NOTIFY` works at all.
- **Something has to be listening** or the notification is delivered to nobody. PostgreSQL does
  not queue notifications for absent listeners, so a `NOTIFY` raised while nothing is listening is
  simply discarded. This matters for the sampler: if your listener is down, you get no alerts and
  no record that you got none.
- **`lock_tree_alert` must be writable by whoever runs the sampler.** The function is not
  `SECURITY DEFINER`, deliberately: it is a decision about what is important enough to tell
  someone, and a role that can set thresholds is a role that can page people.
- **The sampler needs to run as often as you want to know.** Alerting inherits the sample
  interval. Sampling every minute means learning about a minute-long queue a minute late, which is
  usually fine, and sampling every ten seconds means learning in ten seconds at ten times the
  write cost.
## When the queue is too wide to read

A tree is one row per session, which is the right shape for one incident and the wrong shape for
a database having six at once. `lock_tree_text_short()` helps by abbreviating, and stops helping
at several hundred lines. `lock_tree_wide()` aggregates instead:

```sql
SELECT * FROM lock_tree_wide();
```

```
 root_pid |    application_name    |        state        | blocked_sessions | max_depth | longest_wait |      wait_events      |   first_waiting_for
----------+------------------------+---------------------+------------------+-----------+--------------+-----------------------+------------------------
      179 | nightly_reconciliation | idle in transaction |               40 |         1 | 3m12s        | {ClientRead,relation} | AccessShareLock on ledger
      180 | reporting_rollup       | idle in transaction |               15 |         1 | 3m12s        | {ClientRead,relation} | AccessShareLock on ledger_daily
```

Two rows instead of fifty-seven. `lock_tree_summary()` collapses it to one, which is the shape a
dashboard cell or an alert condition wants, and returns zeros on a quiet database rather than no
rows:

```sql
SELECT * FROM lock_tree_summary();   -- blocked_sessions, roots, max_depth, longest_wait, oldest_xact_age
```

### Which query is doing it

`lock_tree_statements()` joins each root to `pg_stat_statements`, which turns "pid 4821 is
holding a lock" into "this statement has run 40,000 times at 180ms mean, and it is what is
blocking you". Two incidents at 09:00 and 14:00 have different pids and the same `queryid`, and
that is what makes them recognisable as one problem:

```sql
SELECT application_name, statement, calls, mean_exec_time, blocked_sessions
FROM lock_tree_statements() WHERE calls IS NOT NULL ORDER BY mean_exec_time DESC;
```

Three things to know before you rely on it:

- **It needs `pg_stat_statements` in `shared_preload_libraries`.** Without it the function still
  works and still reports which roots exist and how much each blocks, with the statement columns
  empty. It never raises, so a dashboard querying it does not need two code paths.
- **It cannot enrich the waiters.** A query blocked on a lock has a `NULL` `query_id` for as long
  as it is blocked, and only gains one when it completes, so the waiter side of the join is empty
  during exactly the moment you would want it. The root is the opposite and always has one.
  This was measured, not assumed; `test/10_statements.sql` pins it.
- **A root that has never run its current statement matches nothing.** `pg_stat_statements`
  records queries as they complete, so the join follows the root's most recent statement.

## A blocker with no backend

A prepared transaction holds its locks until `COMMIT PREPARED` or `ROLLBACK PREPARED`, and it has
no session for the whole of that time. `pg_stat_activity` has no row for it, and `pg_locks.pid` is
`NULL` for every lock it holds.

```sql
postgres=# SELECT gid, prepared, owner FROM pg_prepared_xacts;
```

This is the one thing the usual recursive query cannot do at all, because it walks
`pg_blocking_pids()` and there is no pid to walk to. `pg_lock_tree` reports it as root pid 0, and
its suggested action is `ROLLBACK PREPARED` rather than a `pg_cancel_backend(0)` that could never
have worked.

### Two of them are two roots, which took until 0.8 to get right

`pg_blocking_pids()` reports the blocker as `0` for **every** prepared transaction. So through 0.7
every prepared root had pid 0, and everything that grouped on the pid merged them:

```
 0.7, three prepared transactions and four waiters

 root_pid | blocked_sessions
        0 |                 4        <- one row, and nothing holds four sessions
```

`lock_tree_summary()` reported `roots` as 1. The number an operator acts on was wrong, in the one
case this extension exists to be better than the usual query at.

```
 0.8, the same incident

 root_pid | root_object                         | blocked_sessions
        0 | AccessExclusiveLock on ledger       |                2
        0 | AccessExclusiveLock on orders       |                2
```

**`root_object` is what a prepared-transaction root is holding.** It is `NULL` for a session root,
because `root_pid` already identifies that one, so the two columns together are the root's
identity. It appears:

- on `lock_tree`, as the last column
- on `lock_tree_roots()`, `lock_tree_wide()` and `lock_tree_statements()`, immediately after
  `root_pid`
- on `lock_tree_incidents()`, as `root_objects`, an array, since one incident can involve several
- on `lock_tree_history`, recorded by `lock_tree_sample()`
- in the `NOTIFY` payload from `lock_tree_notify()`
- in `lock_tree_alert`, where it is part of the primary key

It is **always schema-qualified**, so `public.ledger` rather than `ledger`. That is longer than
necessary and deliberate: `regclass` qualifies only when the schema is not in the `search_path`, so
the shorter form would render the same lock two different ways depending on who asked. A value in a
primary key cannot do that.

One limit worth stating: **two prepared transactions holding compatible locks on the same relation
are one root.** PostgreSQL cannot tell them apart either, so attributing a waiter to one of them
would be a guess. Grouping by the object rather than by the lock mode is the honest boundary.

See `scenarios/s7_prepared.sql`, which builds three at once and prints the 0.7 figure for the same
incident so the comparison is measured rather than remembered.

## After the incident has cleared

Everything above describes the present. That is a real limit, and it bites at the worst moment:
incidents are usually noticed once they have ended, by a slow query, a timeout, or someone
reporting that "it was hanging earlier". By then `pg_stat_activity` has moved on and the tree is
empty.

0.4 keeps a history. Opt in, then sample on a schedule:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;          -- once per database, see INSTALL.md
SELECT cron.schedule('lock_tree_sample', '10 seconds', 'SELECT lock_tree_sample()');
SELECT cron.schedule('lock_tree_prune', '1 hour',  'SELECT lock_tree_prune(''1 day'')');
```

Then ask what happened:

```sql
SELECT * FROM lock_tree_incidents() ORDER BY started_at DESC;
```

```
 incident |          started_at          | samples | peak_sessions | depth | longest_wait |  roots  |     applications
----------+----------------------------+---------+---------------+-------+--------------+---------+---------------------
        1 | 2026-10-04 09:12:04.881+01   |      37 |            61 |     2 |       4m12s  | {4821}  | {api_worker,nightly_batch}
```

An incident is a run of samples with no gap longer than `max_gap` between them. `peak_sessions` is
the high-water mark, not a sum: a session seen at four samples was not four sessions.

Four things worth knowing before you turn it on:

- **It is one row per session per sample**, so the chain's shape survives, and it grows by
  `sessions blocked` rows per sample. That is why `lock_tree_prune()` exists and why the second
  cron entry above calls it.
- **A quiet database costs nothing.** Sampling writes no rows at all when nothing is blocked,
  rather than one row saying so.
- **`sampled_at` is the statement timestamp**, so every row of one sample shares an instant. That
  is what makes the grouping work. Using `clock_timestamp()` instead looks right and quietly
  breaks it, because it is evaluated once per row and the sessions of a single sample land
  microseconds apart.
- **Any scheduler works.** `pg_cron` is convenient and needs no host cron, but it requires
  `shared_preload_libraries = pg_cron`. A plain host cron job calling `psql` needs nothing at
  all, and the extension still needs no `shared_preload_libraries` either way.

`test/07_history.sql` covers the sample, the incident grouping and the pruning;
`test/06_cron.sql` covers whether a scheduled job can reach any of it.

## Objects

| Object | Use |
|---|---|
| `lock_tree` (view) | Every session in a blocking chain: `root_pid`, `root_object`, `depth` (0 is the root), `path`, `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age`, `query`, plus user, database, application and client. Ordered root first. `root_object` is what a prepared-transaction root holds, since `root_pid` is 0 for all of them. |
| `lock_tree_roots()` | One row per root blocker, most sessions blocked first, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`. |
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. Full unabbreviated names. |
| `lock_tree_text_short(query_width int DEFAULT 100)` | The same tree with abbreviated modes and states, for when the queue is wide. Measured 17% narrower on a 61-session incident. |
| `lock_tree_actions()` | A written description of each root blocker and its blast radius, ordered by how many sessions each unblocks. Prose only, no runnable statements. `SET lock_tree.actions = off` suppresses it. |
| `lock_tree_command()` | One complete, runnable statement per root blocker, for pasting or for `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can work. |
| `lock_tree_history` (table) | Sampled trees, one row per session per sample. Empty until you schedule a sample. `query_id` on root rows only, since a blocked query has none. |
| `lock_tree_sample()` | Take one snapshot into `lock_tree_history`. Returns rows written, 0 when nothing is blocked. Nothing calls it for you. |
| `lock_tree_incidents(max_gap interval DEFAULT '5 minutes')` | The history grouped into incidents: when each ran, peak sessions blocked, deepest chain, longest wait, and the root pids and application names involved. |
| `lock_tree_prune(older_than interval)` | Delete history older than the given age, return how many. The table only grows otherwise. |
| `lock_tree_wide()` | One row per root instead of one per session: how many sessions each blocks, the deepest chain under it, the longest wait, and what they are waiting for. Use when the tree is too wide to read. |
| `lock_tree_summary()` | One row for the whole queue: sessions blocked, roots, deepest chain, longest wait, oldest root transaction. Zeros on a quiet database, not no rows, so it drops straight into a dashboard. |
| `lock_tree_statements()` | Per root, what `pg_stat_statements` already knows about the query holding the lock: normalised text, calls, mean and total time. Groups incidents by query rather than by pid. Optional; see below. |
| `lock_tree_notify(channel, min_blocked, min_depth, min_wait)` | Raise a `NOTIFY` when a chain is bad enough, and remember it so the same incident notifies once rather than on every sample. Returns how many it raised, so zero is the normal result. |
| `lock_tree_alert` (table) | What `lock_tree_notify()` has already alerted on, per channel, per threshold set, per root. Holds three high-water marks, recorded at the last notification rather than at the last sample. Maintained by the function; you should never need to look at it. |
| `lock_tree_prune_alerts(older_than interval)` | Forget alert state orphaned by a restart or a retired channel. |
| `lock_tree_history_statements(since interval DEFAULT '7 days')` | Per-query blocking time from the sampled history, worst first. Answers "which statement costs the most blocking time", which is the question that gets a fix merged rather than a workaround. |
| `lock_tree_sampling_advice()` | A suggested interval for the sample cron entry, given how busy things are, and why. |
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
sessions this extension does. `scenarios/` builds eight incidents and runs both:

```
  scenario            waiting      std     tree   verdict
  s1_nightly_batch          4        4        4   tie
  s2_three_chains           4        4        4   tie
  s3_row_locks              2        2        2   tie
  s4_wide_queue            60       60       60   tie
  s5_mixed_locks            2        2        2   tie
  s6_deadlock               2        2        2   tie
  s7_prepared               2        0        2   pg_lock_tree +2
  s8_many_roots            66       66       66   tie
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

`s8` is worth reading alongside `s4`. `s4` is a wide queue behind a *single* root, which the
abbreviation work handles. `s8` is a queue that is wide *and* has five heads, where the published
CTE still finds every session and the interesting question becomes "which of my five blockers is
the worst one". That is answered by `lock_tree_wide()` in five rows rather than by reading
seventy-one.

Everything else this extension adds on top: roots named by `application_name`, the blast radius
per root, a ready-made command, rendering that survives a wide queue, and an aggregate for when
rendering is not enough.

Full write-up, including the reasoning behind the coverage metric, in
[scenarios/README.md](scenarios/README.md).

## Development

```bash
make prove              # 221 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all eight scenarios, both tools, output captured
make lint-docs          # the docs still match the code
make check-alert        # prove a real NOTIFY reaches a real listening client
make explain-alert PAYLOAD='…'   # explain a payload you already have, no database needed

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
| `test/07_history.sql` | a live chain sampled into `lock_tree_history`, the rows surviving the incident, the history segmented into incidents, and pruning at both extremes. No `pg_cron` needed |
| `test/08_wide.sql` | a 57-row, two-root queue, checked against `lock_tree` row by row: every count in the wide form must be derivable from the tree, since a summary that disagrees with the tree is worse than none |
| `test/09_cost.sql` | the cost claim the README and the SQL header both make, measured as a ratio against a plain `pg_stat_activity` read rather than a wall-clock ceiling, which is noise on a shared runner |
| `test/10_statements.sql` | `lock_tree_statements()` with and without `pg_stat_statements` loaded: the roots are reported either way, and the join is pinned where it is available |
| `test/11_alert.sql` | alerting, and mostly not alerting: onset fires once, an unchanged chain stays silent, escalation fires on width, on depth and on a doubling wait, `min_wait => NULL` suppresses age escalation entirely, recovery then relapse fires again, and all three thresholds disabled is an error |
| `scripts/check-alert.sh` | the delivery path, which no assertion can check: psql prints notifications to stdout, so this listens from a second client and reads the payload back. `--explain` turns a payload into the queries to run, with no database |
| `test/12_history_statements.sql` | per-query blocking time from written history: only root rows count, the window filter runs before the aggregation, and the figure is session-samples rather than seconds |
| `test/13_prepared_roots.sql` | two prepared transactions are two roots, which is the 0.8 bug: the waiters attach to the right object, every aggregate counts two roots, and alerting tracks them separately |

CI runs the same suite on all six versions. Three files each need a server setting the matrix
images provide (`max_prepared_transactions`, `shared_preload_libraries` for `pg_cron` and
`pg_stat_statements`) and skip themselves where it is absent, rather than failing a build that
was never going to work. None is a runtime requirement: `pg_lock_tree` itself needs no
`shared_preload_libraries`, and the rest of the suite runs without them.

## Roadmap

- **Next**: per-query blocking time. `lock_tree_history` records who waited and for how long, and
  `lock_tree_statements()` says what the blocking query is right now. Joining the two would answer
  "which statement costs the most blocking time this month", which is the question that gets a
  fix merged rather than a workaround. It needs `query_id` on the history rows.
- **Next**: cross-database. The extension lives in each database, as all extensions do, so a queue
  on `reporting` is invisible from `production`. Deliberately **not** planned here: this is a
  per-database diagnostic, and a fan-out sampler is a separate tool wearing this one's name.
- **Next**: deadlocks in the history. `pg_stat_database.deadlocks` is a counter with no attribution,
  so the log is the only place the two statements are named. Recording the counter per sample would
  at least answer "when did deadlocks start here", and a `log_lock_waits`-style hook could name the
  pair. The hook is a bigger change than it looks, because it has to work on a server where nobody
  has installed anything.
- **Next**: `lock_tree_history` partitioned by month, so `lock_tree_prune()` becomes a DETACH
  rather than a DELETE. The table grows by (sessions blocked) x (samples) and is only ever pruned
  by age, which is the shape partitioning suits. It cannot be done in place: 0.4 created the table
  unpartitioned and the rows have to move, so it needs a migration path rather than an ALTER.
- **Later**: show what each root *holds* that its waiters want, not only what the waiters ask for.
- **Untested**: loading through AWS `pg_tle` on RDS and Aurora, where `make install` is not
  possible. Being pure SQL is what makes it plausible. The thing most likely to fail is whether
  `pg_blocking_pids()` is reachable under `pg_tle`, so that is what to check first.