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

New here, start with **[INSTALL.md](INSTALL.md)**.

- **[INSTALL.md](INSTALL.md)**: install, grants, update, uninstall, troubleshooting
- **[CHANGELOG.md](CHANGELOG.md)**: what changed in each release
- **[scenarios/](scenarios/)**: eight incidents, compared against the usual hand-written query
- **[test/](test/)**: 398 pgTAP tests, and what each one pins down

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
{"channel":"lock_tree","event":"alerting","root_pid":179,
 "application_name":"nightly_reconciliation",
 "blocked_sessions":40,"max_depth":2,"longest_wait":"3m12s",
 "waiting_for":"AccessShareLock on ledger"}
```

Every key is always present, `null` excepted where there is genuinely nothing to say. The server
enforces an 8000-byte payload limit and this is far below it.

`event` is **new in 0.12**, and is the only change to this payload. It exists because 0.12 adds a
second kind of notification on the same channel, and a consumer needs one field to branch on rather
than inferring which kind it got from the presence or absence of some other key. It is additive:
JSON consumers read by key, so a listener written before 0.12 that ignores fields it does not
recognise is unaffected.

`application_name` is the one to key on rather than `root_pid`. A pid identifies one session for
as long as that session lives, which is the wrong key for correlating a page with a log or a
dashboard across restarts and reconnects.

### Knowing when it is over

`lock_tree_notify()` says when something starts getting worse and then says nothing, which is
right for a pager and wrong for the person who was woken up. `lock_tree_notify_resolved()` closes
that gap:

```sql
SELECT lock_tree_notify_resolved('lock_tree', 10, 3, '30 seconds');
```

It raises one notification per root that **had alerted** and has since left the tree, with
`event` set to `"cleared"`, then forgets the stored state so the same root blocking again alerts
from the start rather than escalating against a high-water mark from a previous incident. A root
that never alerted produces nothing, because a resolution notice with no matching alert is noise.

```json
{"event":"cleared","channel":"lock_tree","root_pid":179,"root_object":null,
 "application_name":"nightly_reconciliation","blocked_at_most":40,"notified_count":2}
```

`blocked_at_most` and `notified_count` are there so a reader can judge what it was: a cleared root
that had blocked forty sessions and escalated twice is a different thing from one that briefly
blocked two.

It is a separate function rather than a parameter on `lock_tree_notify()` on purpose. An
`alerting`/`cleared` pair on the same channel is what a consumer wants, but whether an incident
ending is worth waking someone is a property of your rota rather than of this extension, and
someone who never wants it should not be able to switch it on by accident through named notation.
Run it from the same cron entry as `lock_tree_notify()`, and pass **the same thresholds**, because
the two key on the same state and a mismatch means resolving alerts that were never sent.

A consumer written before 0.12 that ignores unknown fields is unaffected. One that switches on
`event` gets the pair it needs.

### `lock_tree_alert`, and why you should not need to look at it

One row per notable root per channel per threshold set, holding the high-water marks. It is the
size of the current queue, not of its history, and `lock_tree_notify()` maintains it. You should
never need to touch it.

`lock_tree_prune_alerts()` exists for state orphaned by a restart or a retired channel name, and
is worth calling from the same cron entry as the sample if you care. It is not load-bearing.

### Checking it works

Two ways, and they check different things.

```bash
[`scripts/check-alert.sh`](scripts/check-alert.sh)              # builds a chain, notifies, and reads the notification back
[`scripts/check-alert.sh`](scripts/check-alert.sh) --explain    # the same, then explains the payload it received
[`scripts/check-alert.sh`](scripts/check-alert.sh) --explain '{"root_pid":0,...}'
```

That verifies the delivery path end to end, which no assertion can: `psql` prints notifications to
stdout and a TAP test cannot see stdout, so the stream is checked by a real second client. It also
asserts the payload **sequence**, which is how the silence check can be trusted: exactly two
payloads arrive, `alerting` then `cleared`, so a function that returned 0 while still sending
something would be caught.

`test/11_alert.sql` verifies the decisions, which is the part worth unit-testing: onset fires once,
an unchanged chain stays silent, escalation fires on width and on depth, age escalates only on a
doubling, recovery then relapse fires again, thresholds behave, and all three disabled is an error.
`test/16_duration_resolved.sql` covers the resolution notices: nothing on a quiet database, one
per cleared root, none while the incident is still standing, and the state forgotten afterwards.

### What to do when one arrives

`--explain` takes the payload and prints what it means, the queries to run in order, and what not
to do. It needs **no database**, which is the point: the first thing you do at 3am should be
something that cannot fail because the database is the thing that is broken.

```
$ [`scripts/check-alert.sh`](scripts/check-alert.sh) --explain '{"root_pid":0,
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

It is sized on the **widest queue in the window**, not on the queue at the instant. That is the
whole point, and getting it wrong is easy: a cron entry that runs at 3am on a quiet Sunday would
otherwise recommend the finest interval for a database that spends every weekday morning with four
hundred sessions waiting. The advice was not wrong about the instant; it was answering the wrong
question.

```
 blocked_sessions | roots | suggested_every |             reason              | observed_peak | live_blocked
------------------+-------+-----------------+---------------------------------+---------------+--------------
              450 |     9 | 00:00:30        | a wide queue: each sample      |           450 |            0
                 |       |                 | writes a row per blocked       |               |
                 |       |                 | session, so widen the interval |               |
                0 |     0 | 00:00:05        | nothing blocked now and        |             0 |            0
                 |       |                 | nothing in the window: the     |               |
                 |       |                 | table stays empty at any       |               |
                 |       |                 | interval, so sample rarely     |               |
```

`observed_peak` and `live_blocked` are both returned, and the figure used is the greater of the two,
so a queue that started after the last sample is not ignored and the advice can be traced back to
what it was based on.

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

### Which query is costing the most time

The query above tells you which statement is blocking the most sessions *right now*. Over a week
the more useful question is which one cost the most blocking time, and that is a different
function answering a different question.

```sql
SELECT query_id, blocking_seconds, blocked_sessions_peak, gaps, applications
FROM lock_tree_duration() LIMIT 20;
```

`lock_tree_duration()` reports, per root query id, how long that statement was the thing holding
the queue up. The two are not substitutes, and the difference is worth knowing before you pick:

| | `lock_tree_history_statements()` | `lock_tree_duration()` |
|---|---|---|
| The unit | session-samples | seconds |
| Sample twice as often | doubles | unchanged |
| Answers | which statement blocks the most sessions | which statement costs the most blocking time |

That middle row is the whole reason this exists. Measured on one six-second incident sampled at
two different rates:

```sql
-- the same incident, three samples over 6s, then six more over the next 6s
--                  session-samples   gap-summed time
--  3 samples / 6s            3          00:00:06
--  + 6 more   / 6s           9          00:00:06
```

One figure tracked elapsed time and the other tracked observations. Ranking statements by a number
that moves when you change your cron entry is ranking them by your cron entry, which is a thing you
would have to notice and explain to someone.

Where a duration comes from, since samples record instants and instants have no length in them.
Each row in the history is a moment. Duration lives in the **gaps between moments**: while this
query was the root at both `t0` and `t1`, it was the root for the whole of `t0` to `t1`. Summing
those gaps is a measurement rather than an interpolation, because both endpoints are instants at
which the query demonstrably held the queue up. A gap whose far end has a **different** root is
discarded rather than split: nobody observed when the handover happened, so any apportionment
would be invented. `gaps` and `gaps_excluded` report both, so you can see how much was left out.

Two things it does not claim:

- **The interval after the last sample.** A chain still standing when the sampler last ran
  contributed time nobody measured. This is a lower bound and says so.
- **Anything at all without a sampled history.** Both functions need
  [`lock_tree_sample()`](#choosing-an-interval) scheduled, and neither will invent figures from a
  table that has never been written to.

### Which application is costing the most

Per statement is the right unit when you are fixing one query. It is the wrong unit for the question
a page actually asks, which is which *service* is costing the most, and the two are not
interchangeable:

```sql
SELECT application_name, blocking_seconds, blocked_sessions_peak, longest_wait, query_ids
FROM lock_tree_duration_by_application() LIMIT 20;
```

The tempting thing is to sum `lock_tree_duration()` by application. That gives the wrong answer, and
it is wrong in the direction that matters.

A batch job holding the queue for ten minutes will very likely hand the queue from one statement to
another while it does it, because that is what a fixed script does. Say its statement 1 is the root
at `t0` and its statement 2 is the root at `t1`:

| | the gap from `t0` to `t1` |
|---|---|
| `lock_tree_duration()` | **discarded**: neither statement was the root at both ends |
| `lock_tree_duration_by_application()` | **counted**: the application was holding the queue at both ends, and from where the application is concerned nothing changed |

So summing the per-query figures reports the time the application spent blocking *minus* every
handover. Measured on a single six-sample incident with one handover: the per-query sum was **4.0
seconds** where the application had actually held the queue for **15.4**. A service that blocked
forty sessions for a quarter of an hour could be reported as having cost two seconds, and nobody
would notice, because the number is small and plausible.

That is why `lock_tree_duration_by_application()` does the gap arithmetic again on
`(sampled_at, application_name)` rather than aggregating the per-query output. Everything else is
identical, including the same conservatism: a gap where the **application** was not at the far end
is discarded, and the interval after the last sample is never counted.

### The two figures are not always ordered the same way

`query_id` identifies a **statement**, not who ran it. Two services running identical text share one
`query_id`, so `lock_tree_duration()` reports one row covering both, while
`lock_tree_duration_by_application()` reports two. That inverts the comparison:

- **A handover between different statements inside one application** (the batch job above).
  Per-application is the larger figure, because the per-query rule threw the handover gap away.
- **The same statement handed between two applications.** Per-query is the *larger* figure, because
  the statement is identical on both sides of the handover so every gap has it at both ends, while
  the per-application rule discards that gap as attributable to neither service.

Neither is wrong. The per-query figure answers "what does this statement cost, including the time it
spent blocking under two different services". The per-application figure answers "what did each
service cost", and comes out lower because a handover between two services is not attributable to
either. `test/17_duration_by_application.sql` pins both directions.

### Before you query a week of history

Every windowed function takes a `since` and, since 0.15, seeks rather than scanning. On a seven day
history of 1.2 million rows and 264 MB, measured with `make bench-history`:

```sql
SELECT * FROM lock_tree_duration(interval '1 hour');        -- not interval '7 days'
SELECT * FROM lock_tree_duration_by_application(interval '1 day');
```

Before 0.15 the window was a filter over the whole index, so the cost tracked the size of the
**history** rather than the window you asked for, and a dashboard asking about the last hour paid for
the last week. It now does not. The seven day figures are still the slowest reads in the extension,
because seven days of samples is genuinely 60,481 instants and 1.2 million rows of work.

One thing changed in 0.15 that you may have built something on top of: `blocked_sessions_peak` and
`sessions_total` in both duration functions were **one too high per sample**, because the
root-to-waiter join matched each root to itself. A root blocking three sessions reported four.

### One fix worth knowing about

0.12 reported three columns of `lock_tree_duration()` that could not be right, and 0.13 corrects
them. All three came from one mistake: a root's **identity** and the waits it **caused** are on
different rows. `query_id` is on the root row, `wait_age` is on the waiter's, so:

| | 0.12 | 0.13 |
|---|---|---|
| `longest_wait` | always `NULL` | the longest wait it caused |
| `blocked_sessions_peak` | always `1` | the peak sessions behind it |
| `sessions_total` | a second copy of `samples` | that peak summed over the instants |

One join fixes all three, the root rows of a sample matched to the waiter rows of the **same** sample
on `root_pid` and `root_object`. If you wrote a query against 0.12 that relied on
`blocked_sessions_peak` being 1, it was reading a bug rather than a fact.

### One hazard worth knowing before you schedule anything

The samples must be **separate statements**. `sampled_at` is `statement_timestamp()`, which is fixed
for the duration of a statement, so a loop of samples inside a single `DO` block collapses onto one
instant:

```sql
-- WRONG: four samples, one instant, four seconds of incident invisible to the history
DO $$ BEGIN FOR i IN 1..4 LOOP PERFORM lock_tree_sample(); PERFORM pg_sleep(1); END LOOP; END $$;

-- RIGHT: four samples, four instants, and lock_tree_duration() can sum the gaps
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();
```

The rows are written either way, so the history looks healthy unless you count instants rather than
rows. A `cron` entry has no such problem, since each run is its own statement. `test/16_duration_resolved.sql`
pins this down with the measurement rather than only describing it.

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

## Deadlocks

A deadlock is not a queue. It is a cycle: two sessions each waiting for the other, with nobody at
the head. `scenarios/s6_deadlock.sql` builds one and the tree reports both sessions at depth 0,
each its own root, because there is no root in the usual sense.

What the extension could not do was say anything about them afterwards.

`pg_stat_database.deadlocks` is a counter, present since PostgreSQL 13 and therefore on every
version supported here. `lock_tree_sample()` now records it, and `lock_tree_deadlocks()` reports
when it moved.

```sql
postgres=# SELECT * FROM lock_tree_deadlocks(interval '7 days');
```

### Why the counter is sampled into its own table

This is the part worth understanding, and it is not tidiness.

`lock_tree_history` only has rows while something is **blocked**. PostgreSQL resolves a deadlock by
killing one participant. So by the time your sampler runs, the cycle is over, the tree is empty,
and there is no history row to hang a counter on. Measured, on the run in
`scripts/check-deadlock.sh`:

```
 the counter moved, from 15 to 16
 and nothing is blocked now, so lock_tree_history would record nothing at all
 a sample wrote no history rows, because the tree is empty
 and lock_tree_deadlocks() reports the move: delta = 1
```

A deadlock you did not happen to be looking at is exactly the one worth catching, and putting the
counter on `lock_tree_history` would miss all of them. So `lock_tree_deadlock` is one row per
sample, written whether or not anything is blocked. `lock_tree_prune()` clears it with the history,
so there is still only one thing to remember.

### What it cannot tell you

**It does not name the two statements.** Nothing in SQL does. The participants exist only in the
server log:

```
ERROR:  deadlock detected
DETAIL:  Process 1234 waits for ShareLock on transaction 5678; blocked by process 5678.
Process 5678 waits for ShareLock on transaction 1234; blocked by process 1234.
```

`pg_stat_database.deadlocks` is a bare number with no attribution, and this extension does not
pretend otherwise. What it gives you is the **timestamp**, and that is the half that makes the log
worth reading: with three deadlocks all between 09:00 and 09:15 on a Monday morning, you are looking
at a deploy or a cron job rather than at a mystery.

To get the statements, enable the log entry and correlate:

```conf
# postgresql.conf, then restart
log_lock_waits = on
log_min_duration_statement = 0     # optional: every statement, so the CONTEXT lines are there too
```

Deadlock messages are logged at `ERROR` and do not need `log_lock_waits`; that setting is for
lock *waits*, which is the other half of this problem and the one `log_lock_waits` makes visible.

### Counter resets

`pg_stat_database.deadlocks` can go **backwards**: `pg_stat_reset_shared('db')` sets it to zero.
A naive delta would then be negative, which is not a number of anything. So:

| | |
|---|---|
| `delta` | never negative, because a falling counter is not negative deadlocks |
| `counter_reset` | set when the counter fell, so the timeline admits the discontinuity |
| `total_in_window` | sums the deltas **after** any reset, so a reset cannot silently understate it |

### Sampling it

```
 -- see the whole queue right now
 SELECT * FROM lock_tree_summary();

 -- when deadlocks happened, over the last week
 SELECT * FROM lock_tree_deadlocks();

 -- prune everything older than a day, history and deadlock samples together
 SELECT lock_tree_prune(interval '1 day');
```

`lock_tree_prune()` returns the number of **history** rows it removed, not the total across both
tables. It has returned a history count since 0.4 and every existing caller reads that number; at a
five second sample interval, counting the deadlock rows as well would inflate it by a factor of the
sample rate for no benefit. The deadlock rows are still deleted.

### Checking it works

```bash
[scripts/check-deadlock.sh](scripts/check-deadlock.sh)
```

A script rather than a test file, for the same reason as [`scripts/check-alert.sh`](scripts/check-alert.sh) and for a more annoying
reason: the increment lands when the server breaks the cycle, which is `deadlock_timeout` after the
wait began. Three separate attempts to observe that inside a single psql session all failed, each
differently. Building the deadlock from dblink connections belonging to the session that was also
sampling made the two interfere; waiting on the counter is circular, since the counter only moves
once the server has acted; and waiting for the cycle first only worked once the sample was a separate
process.

`scenarios/s6_deadlock.sql` builds a real deadlock too, but it raises `deadlock_timeout` to 15s so
the cycle survives long enough to be photographed, which means the increment lands long after that
scenario has moved on. So the two lived in different places, until the parameter that separates
them became a parameter:

```bash
[scripts/check-deadlock.sh](scripts/check-deadlock.sh)                              # default 1s, waits for the move
[scripts/check-deadlock.sh](scripts/check-deadlock.sh) --deadlock-timeout=15s        # s6's timeout, proves both halves
[scripts/check-deadlock.sh](scripts/check-deadlock.sh) --deadlock-timeout=2s         # breaks it promptly
```

With `15s` the script builds the cycle, observes it in `pg_stat_activity`, and checks that the
counter has **still not moved**. That is the state [`scenarios/s6_deadlock.sql`](scenarios/s6_deadlock.sql) photographs, proved rather
than assumed, and it is the answer to the question that sends people to the source: *I can see a
deadlock but `deadlocks` has not moved, is something broken?* Nothing is broken. The counter moves
when the server breaks the cycle, and not before.

The setting is applied to the two victim sessions only. Your `postgresql.conf` is not touched.

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

## Replaying an incident that has ended

The history answers questions about totals. It cannot show you the **shape**: sixty sessions behind
one idle-in-transaction root at depth three, or five independent roots at once. That shape is what
you remember three days later, and by then the queue has cleared and the tree is gone.

```sql
-- which moments can you ask about? The history holds one row per session, so its own row
-- count is a count of observations, not of moments.
SELECT * FROM lock_tree_replay_samples ORDER BY sampled_at DESC LIMIT 10;

-- then ask about one
SELECT * FROM lock_tree_replay_text(now() - interval '2 hours');
```

`lock_tree_replay(as_of)` returns the rows if you would rather query than read, and
`lock_tree_replay_text(as_of, query_width)` renders them in `lock_tree_text()`'s layout, so a replay
and the live tree look the same:

```
4821  idle in transaction  nightly_batch  UPDATE ledger SET amount = amount WHERE id = 1
 └─4822  3m12s  for AccessExclusiveLock on public.ledger  SELECT count(*) FROM ledger
   └─4823  3m10s  for AccessShareLock on public.ledger   INSERT INTO audit VALUES (1)
   └─4824  3m09s  for AccessShareLock on public.ledger   INSERT INTO audit VALUES (2)
```

Two things to know before you rely on it:

- **`as_of` is a target, not an exact key.** The sample **nearest** it is used, and `sampled_at` is
  the first column of every row, so you can see which one you actually got rather than assuming. A
  target between two samples picks the closer one. `NULL` means the most recent.
- **Nine columns of `lock_tree` are not here**, and that is deliberate rather than an oversight.
  `path` and `blocked_by` cannot be reconstructed: the history stores one row per session, not the
  edge between them, so nothing says which depth-1 session a depth-2 session was actually behind.
  `usename`, `datname`, `client_addr`, `wait_event_type`, `wait_event`, `xact_age` and `state_age`
  were simply never recorded, and adding them now would widen the history for every future sample on
  every database without retroactively supplying the past.

`waiting_for` reads back schema-qualified where the live view does not, because `lock_tree_sample()`
runs with `search_path = pg_catalog` and `regclass` cannot resolve unqualified there. That is the
better of the two renderings: the live one is path-dependent, and the history's says
`public.ledger` in every row forever.

`test/18_replay.sql` pins all of it, including the absent column list asserted **by name** rather
than by count, since "which nine" is the part a reader needs.

And, once you have more than one incident's worth of history, which statement cost the most
blocking time across all of them:

```sql
SELECT query_id, blocking_seconds, blocked_sessions_peak, applications
FROM lock_tree_duration() LIMIT 20;
```

That is the question that gets a fix merged rather than a workaround, and it is a different
function from [`lock_tree_statements()`](#which-query-is-doing-it), which answers it for the queue
in front of you right now. See
[Which query is costing the most time](#which-query-is-costing-the-most-time) for why the two
disagree and which one to reach for.

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

> **Monitoring roles.** Seven of the functions below read `lock_tree_history` and are
> `SECURITY INVOKER`, so they need `GRANT SELECT ON lock_tree_history` on top of the two grants in
> [INSTALL.md](INSTALL.md#grants). `lock_tree_replay_samples` is a view and works without it, because
> a view runs with the definer's rights. That inconsistency is stated rather than fixed, and the
> reasons are in INSTALL.md.

| Object | Use |
|---|---|
| `lock_tree` (view) | Every session in a blocking chain: `root_pid`, `root_object`, `depth` (0 is the root), `path`, `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age`, `query`, `query_id`, plus user, database, application and client. Ordered root first. `root_object` is what a prepared-transaction root holds, since `root_pid` is 0 for all of them. `query_id` was added in 0.16 so the live tree can be joined to `lock_tree_history` on it; it is `NULL` on waiters, because a blocked query has none until it completes. |
| `lock_tree_roots()` | One row per root blocker, most sessions blocked first, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`. |
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. Full unabbreviated names. |
| `lock_tree_text_short(query_width int DEFAULT 100)` | The same tree with abbreviated modes and states, for when the queue is wide. Measured 17% narrower on a 61-session incident. |
| `lock_tree_actions()` | A written description of each root blocker and its blast radius, ordered by how many sessions each unblocks. Prose only, no runnable statements. `SET lock_tree.actions = off` suppresses it. |
| `lock_tree_command()` | One complete, runnable statement per root blocker, for pasting or for `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can work. |
| `lock_tree_history` (table) | Sampled trees, one row per session per sample. Empty until you schedule a sample. `query_id` on root rows only, since a blocked query has none. |
| `lock_tree_deadlock` (table) | `pg_stat_database.deadlocks` sampled on its own beat, whether or not anything is blocked. Naming no participants: the two statements are in the server log. Pruned by `lock_tree_prune()`. |
| `lock_tree_sample()` | Take one snapshot into `lock_tree_history`. Returns rows written, 0 when nothing is blocked. Nothing calls it for you. |
| `lock_tree_incidents(max_gap interval DEFAULT '5 minutes')` | The history grouped into incidents: when each ran, peak sessions blocked, deepest chain, longest wait, and the root pids and application names involved. |
| `lock_tree_prune(older_than interval)` | Delete history older than the given age, return how many **history** rows went, which is what it has always returned. The table only grows otherwise. |
| `lock_tree_history_size()` | What the history costs now and what it will cost at the rate it is already being written: rows, samples, total bytes, the observed sample interval, bytes per day, and days until it reaches a gigabyte. |
| `lock_tree_prune_batched(older_than interval, batch_size integer)` | A **procedure**, not a function. The same prune in committed batches, so no single lock is held for the whole of it. Cannot be called inside a transaction block, and checks for one before deleting anything. |
| `lock_tree_wide()` | One row per root instead of one per session: how many sessions each blocks, the deepest chain under it, the longest wait, and what they are waiting for. Use when the tree is too wide to read. |
| `lock_tree_summary()` | One row for the whole queue: sessions blocked, roots, deepest chain, longest wait, oldest root transaction. Zeros on a quiet database, not no rows, so it drops straight into a dashboard. |
| `lock_tree_statements()` | Per root, what `pg_stat_statements` already knows about the query holding the lock: normalised text, calls, mean and total time. Groups incidents by query rather than by pid. Optional; see below. |
| `lock_tree_notify(channel, min_blocked, min_depth, min_wait)` | Raise a `NOTIFY` when a chain is bad enough, and remember it so the same incident notifies once rather than on every sample. Escalates on more sessions, more depth, or a longest wait that has **doubled**. Returns how many it raised, so zero is the normal result. |
| `lock_tree_notify_resolved(channel, min_blocked, min_depth, min_wait)` | Raise one `NOTIFY` with `event: "cleared"` per root that **had alerted** and has now left the tree, then forget the stored state so the next incident alerts from the start. Same thresholds as `lock_tree_notify()`, and it reads and writes the same rows. Optional; see below. |
| `lock_tree_deadlocks(since interval DEFAULT '7 days')` | When `pg_stat_database.deadlocks` moved: the cumulative counter, how far it moved, whether it was reset, and the window total. Names no participants; the timestamp is how you find the log entry. |
| `lock_tree_alert` (table) | What `lock_tree_notify()` has already alerted on, per channel, per threshold set, per root. Holds three high-water marks, recorded at the last notification rather than at the last sample. Maintained by the function; you should never need to look at it. |
| `lock_tree_prune_alerts(older_than interval)` | Forget alert state orphaned by a restart or a retired channel. |
| `lock_tree_history_statements(since interval DEFAULT '7 days')` | Per-query blocking from the sampled history as **session-samples**: one unit per blocked session per sample. Answers "which statement blocks the most sessions", which is the right question when the shape of the damage matters more than its cost. Does not move with the sample rate in units of time, because it is not a time; see the next row. |
| `lock_tree_duration(since interval DEFAULT '7 days')` | Per-query blocking **TIME** from the sampled history, worst first: for each root query id, the elapsed time during which it was holding the queue up, with the peak and total sessions it blocked and the longest single wait it caused. Does not move with the sample rate, which is the whole difference. A gap counts only where the query was the root at both ends, and the interval after the last sample is never counted, so it is a lower bound rather than an estimate. |
| `lock_tree_duration_by_application(since interval DEFAULT '7 days')` | The same **TIME**, keyed on `application_name` instead of the statement, with the statements it was root for. Not the same figure and not a re-grouping: see [Which application is costing the most](#which-application-is-costing-the-most). An empty `application_name` is reported as its own row, because a blocker that never set one is a finding. |
| `lock_tree_replay_samples` (view) | One row per sample in the history: when it was taken, how many roots were blocking, how many sessions behind them, how deep, the longest wait, and the applications and query ids at the head. The history holds one row per *session*, so this is how you find out which moments you can ask for. |
| `lock_tree_replay(as_of timestamptz DEFAULT NULL)` | The lock tree as it was at a past sample, from the history. Takes a target and uses the sample **nearest** it, reporting which one in `sampled_at`. `NULL` means the most recent. |
| `lock_tree_replay_text(as_of timestamptz DEFAULT NULL, query_width int DEFAULT 60)` | The same, indented, in `lock_tree_text()`'s layout. For reading about an incident at 4pm rather than during it. |
| `lock_tree_sampling_advice(since interval DEFAULT '7 days')` | A suggested interval for the sample cron entry, sized on the **widest queue in the window** rather than on the queue at this instant, with the reasoning and both inputs returned. |
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
make prove              # 398 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all eight scenarios, both tools, output captured
make lint-docs          # the docs still match the code
make check-alert        # prove a real NOTIFY reaches a real listening client
make check-deadlock     # prove a real deadlock moves the counter and the sample records it
make check-deadlock DEADLOCK_TIMEOUT=15s   # same, with s6's timeout: proves the cycle AND the counter
make bench-history      # time the read side against a synthetic 1.2M row history (truncates it)
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
| `scripts/check-deadlock.sh` | that a **real** deadlock moves the counter and the sample records it. Separate process, because the increment lands on a timer and three attempts inside one psql session all failed |
| `test/12_history_statements.sql` | per-query blocking time from written history: only root rows count, the window filter runs before the aggregation, and the figure is session-samples rather than seconds |
| `test/13_prepared_roots.sql` | two prepared transactions are two roots, which is the 0.8 bug: the waiters attach to the right object, every aggregate counts two roots, and alerting tracks them separately |
| `test/14_deadlocks.sql` | the deadlock counter: a sample on a quiet tree still records it, a delta is a subtraction and never negative, a reset is reported as a reset, and the sampling advice is sized on the history's peak rather than on the instant |
| `test/15_history_size.sql` | the sizing report (zeros and NULLs on an unsampled database, a real rate when there is one), and that a `CALL` inside a transaction block is refused **having deleted nothing** |

CI runs the same suite on all six versions. Three files each need a server setting the matrix
images provide (`max_prepared_transactions`, `shared_preload_libraries` for `pg_cron` and
`pg_stat_statements`) and skip themselves where it is absent, rather than failing a build that
was never going to work. None is a runtime requirement: `pg_lock_tree` itself needs no
`shared_preload_libraries`, and the rest of the suite runs without them.

## Stability, from 1.0.0

**The promise, in one line:** the names, arguments, and output column names and order of the
functions listed as stable below will not change in a minor or patch release. Anything not listed as
stable may change in a patch release, and this document says which is which.

This is the first release to make a promise rather than imply one, and it is narrower than "nothing
will change". A narrower promise that is kept is worth more than a broad one that is not.

### Stable

The **names**, **argument lists** (names, types, defaults, and order), and **returned column names and
order**, of:

| Group | Objects |
|---|---|
| Incident | `lock_tree` (view), `lock_tree_roots()`, `lock_tree_text()`, `lock_tree_text_short()`, `lock_tree_wide()`, `lock_tree_summary()`, `lock_tree_actions()`, `lock_tree_command()` |
| History | `lock_tree_history` (table), `lock_tree_sample()`, `lock_tree_prune()`, `lock_tree_prune_batched()` (procedure), `lock_tree_history_size()`, `lock_tree_incidents()`, `lock_tree_statements()`, `lock_tree_history_statements()`, `lock_tree_sampling_advice()` |
| Analysis | `lock_tree_duration()`, `lock_tree_duration_by_application()`, `lock_tree_replay()`, `lock_tree_replay_text()`, `lock_tree_replay_samples` (view), `lock_tree_replay(as_of)`, `lock_tree_deadlocks()` |
| Alerting | `lock_tree_notify()`, `lock_tree_notify_resolved()`, `lock_tree_alert` (table), `lock_tree_prune_alerts()` |
| Redaction | `lock_tree_redact()`, and the `lock_tree.history_query` setting with its three values |

`lock_tree_alert` is stable as a **relation you do not read**. Its columns are documented as internal
state and the upgrade path rebuilds its column order; see the next section.

### NOTIFY payload keys: additive only

Existing keys keep their names and their types. New keys may be added. A consumer must ignore keys it
does not recognise, and this is the one place where that is a requirement rather than good manners.

### Not stable

- **The three formatting helpers**, `lock_tree_age()`, `lock_tree_mode_short()` and
  `lock_tree_state_short()`. They exist so the renderers can be compared against each other and are
  exposed for that; their output is an implementation detail of the renderers, and changing it is not
  a break.
- **Table column order, and therefore `SELECT *` on the tables.** Not a choice, and the evidence is in
  `scripts/check-upgrade.sh`: `ALTER TABLE ADD COLUMN` appends, so a database older than 0.8 keeps
  `root_object` at the end of the row and displaces what followed it. Every upgrade path converges on
  everything else, and the position difference is a named, checked exception rather than an ignored
  one. **Name your columns.** The view is the interface and it names all of them.
- **What `lock_tree_redact()` removes.** A patch release may widen what it redacts, and that counts as
  a fix rather than a break. Three releases have widened it: 1.0.0 leaked a real SCRAM verifier and
  four `PASSWORD` shapes, and 1.0.1 closed them. If you were relying on something being stored
  verbatim, that is what `lock_tree.history_query = 'full'` is for.
- **`lock_tree_alert`'s columns**, as above.
- **The internal SQL of any function.** The behaviour is stable; the text is not, and `test/19`
  asserts on a few source properties, so a refactor may need to update it.

### Also not a promise

- **The three tables are not registered for `pg_dump`.** That is a decision with reasons in
  [Backups and restores](INSTALL.md#backups-and-restores), pinned by a test, and a future release may
  register them behind a documented option.
- **Cross-database visibility.** Each database has its own history. A fan-out sampler is a separate
  tool; see the [roadmap](README.md#roadmap).
- **Anything about a server where `make install` is not possible**, such as RDS and Aurora. Being pure
  SQL is what makes it plausible and nothing more.

## Roadmap

Rewritten at 1.0.1. The previous version was written at 0.12 and described work that was finished,
plus two items that had gone stale in opposite directions. It is organised by what the evidence
supports rather than by release, and every item says how we know.

### Immediate, and in this order

| # | Work | Why here | Size |
|---|---|---|---|
| 1 | **Non-public schema install test** | The last correctness gap from the 0.14 plan. `lock_tree_sample()` and `lock_tree_redact()` pin `search_path = pg_catalog`, which is exactly where an unqualified sibling reference would break. One matrix case: `CREATE SCHEMA lt; CREATE EXTENSION pg_lock_tree SCHEMA lt;` then the suite with `lt` off `search_path`. | Small |
| 2 | **README split, and the nine corrections** | The largest item and the only one with no correctness or security edge. Items (g) and (h) are mechanical and `scripts/lint-docs.sh` can assert them; (a) to (d) are textual and can be grep-asserted; (e) and (f) need regenerated examples. | 1 to 2 evenings |
| 3 | **Whole-window `lock_tree_duration()`** | Still the slowest read in the extension, and 0.15 and 0.16 both left it there. A seven day window is 60,481 instants and 1.2 million rows of real work, so no index removes it; the four CTEs each re-read the history and merging them is the obvious thing to try. `scripts/bench-history.sh` measures it, which is the only reason the number is knowable. | Untested idea |

### Considered and not planned

- **Cross-database.** The extension lives in each database, as all extensions do, so a queue on
  `reporting` is invisible from `production`. Deliberately not here: this is a per-database
  diagnostic, and a fan-out sampler is a separate tool wearing this one's name.
- **`lock_tree_history` partitioned by month**, so `lock_tree_prune()` becomes a DETACH rather than a
  DELETE. The shape suits partitioning and PostgreSQL has no `ALTER TABLE ... SET PARTITIONED BY`, and
  the copy-and-swap cannot be done from outside the extension because the table is a member.
  Measured, and the reasoning is in the 0.11 changelog. `lock_tree_history_size()` and
  `lock_tree_prune_batched()` are what replaced it.
- **Registering the tables for `pg_dump`.** Decided against, with reasons per table, and the decision
  is now pinned by a test and written up in [INSTALL.md](INSTALL.md#backups-and-restores). The short
  version: `lock_tree_history` grows without bound and describes pids and timestamps that mean
  nothing on the server a restore lands on; `lock_tree_alert` is hysteresis for roots that exist only
  on the source; `lock_tree_deadlock` is a counter baseline whose target starts again from zero.
- **Column order on the tables.** Cannot be made consistent across install paths, and the evidence is
  in `scripts/check-upgrade.sh`: `ALTER TABLE ADD COLUMN` appends, so a database older than 0.8 keeps
  `root_object` at the end of the row and displaces what followed it. Rebuilding `lock_tree_history`
  to reorder it would need twice the disk and hold `ACCESS EXCLUSIVE` for the length of the copy.
  Instead the difference is a named, checked exception, and the stability statement says `SELECT *` on
  the tables is outside the contract.

### Open questions, not commitments

- **What each root *holds* that its waiters want**, not only what the waiters ask for. The wait side is
  reported; the hold side is `pg_locks` and the lock tags, and the interesting version is a diff
  against what the waiter is asking for.
- **A `log_lock_waits`-style hook** naming both sides of a deadlock. The counter is recorded, and the
  two statements are in the server log with no attribution. A bigger change than it looks: it has to
  work on a server where nobody has installed anything.
- **`pg_tle` on RDS and Aurora**, where `make install` is not possible. Being pure SQL is what makes
  it plausible. The thing most likely to fail is whether `pg_blocking_pids()` is reachable under
  `pg_tle`, so that is what to check first.
- **How large a history is too large.** `lock_tree_history_size()` reports it and
  `lock_tree_sampling_advice()` suggests an interval, but neither says when the read side becomes the
  problem instead of the write side. That number is a judgement, and nobody has made it.

### Done, and where to read about it

Recorded here so the section is a record rather than a wish list. Each is one line because the
changelog has the detail and a test has the proof.

- **Per-query blocking time** (0.12), and per-application (0.13), which invert each other depending on
  whether one application runs several statements or several applications run the same one.
- **Recovery notices** (0.12), so an alert has an end and not only a start.
- **The read side seeking instead of scanning** (0.15), after fifteen window bounds used a volatile
  clock and could not become index bounds.
- **Replaying an incident that has ended** (0.14), and `query_id` on the live view (0.16) so the tree
  can be joined to the history.
- **Credential redaction** (1.0.0), fixed and broadened in 1.0.1, with the rows written before 1.0.0
  scrubbed at upgrade time.
- **Verifying every upgrade path** (1.0.0), with the column-position difference it cannot fix
  classified rather than ignored.
