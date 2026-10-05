# after the incident: what it actually cost

**For: whoever gets the afternoon afterwards.** Replaying an incident that has ended, grouping the
history into incidents, ranking by time rather than by count, and the deadlock report.

```
-- replay one incident, given its id, as if it were happening now
SELECT * FROM lock_tree_replay(42);

-- every incident in a window, worst first
SELECT * FROM lock_tree_incidents(interval '7 days');

-- where the blocking time went, per statement and per application
SELECT * FROM lock_tree_duration(interval '1 hour');
SELECT * FROM lock_tree_duration_by_application(interval '1 hour');
```


## The tree is gone; the history is not

Everything on the rest of this page describes the present. That is a real limit, and it bites at the
worst moment:
incidents are usually noticed once they have ended, by a slow query, a timeout, or someone
reporting that "it was hanging earlier". By then `pg_stat_activity` has moved on and the tree is
empty.

So the history is opt-in. Sample it on a schedule:

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
 └─4822  3m12s  for AccessShareLock on public.ledger   SELECT count(*) FROM ledger
   └─4823  3m10s  for RowExclusiveLock on public.ledger  INSERT INTO audit VALUES (1)
   └─4824  3m09s  for RowExclusiveLock on public.ledger  INSERT INTO audit VALUES (2)
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
function from [`lock_tree_statements()`](incident.md#which-query-is-doing-it), which answers it for the queue
in front of you right now. See
[Which query is costing the most time](incident.md#which-query-is-costing-the-most-time) for why the two
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

## Deadlocks

A deadlock is not a queue. It is a cycle: two sessions each waiting for the other, with nobody at
the head. `scenarios/s6_deadlock.sql` builds one and the tree reports both sessions at depth 0,
each its own root, because there is no root in the usual sense.

What the extension could not do was say anything about them afterwards.

`pg_stat_database.deadlocks` is a counter, present since PostgreSQL 9.2 and therefore on every
version supported here. `lock_tree_sample()` now records it, and `lock_tree_deadlocks()` reports
when it moved.

```
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
# postgresql.conf, then SELECT pg_reload_conf() -- both of these are reloadable, no restart
log_lock_waits = on
```

**You do not need `log_min_duration_statement = 0`, and you should not set it.** A deadlock is logged
at `ERROR` and the entry names both processes with the statement each was running, at default logging:

```
ERROR:  deadlock detected
DETAIL:  Process 633 waits for ShareLock on transaction 574; blocked by process 634.
DETAIL:  Process 634 waits for ShareLock on transaction 573; blocked by process 633.
CONTEXT:  while updating tuple (1,1) in relation "ledger"
STATEMENT:  UPDATE ledger SET amount = amount WHERE id = 1
```

Setting `log_min_duration_statement = 0` logs every statement the server runs, which on a busy database
is a large volume of log for information the deadlock entry already carries.

Both settings have context `superuser` in `pg_settings`, which is how to tell a reloadable setting from
one needing a restart:

```sql
SELECT name, context FROM pg_settings WHERE name IN ('log_lock_waits', 'log_min_duration_statement');
```

`log_lock_waits` is for lock *waits*, which is the other half of this problem and not the same thing:
deadlock messages are logged whether or not it is on.

### Counter resets

`pg_stat_database.deadlocks` can go **backwards**: `pg_stat_reset()` sets it to zero. A naive delta
would then be negative, which is not a number of anything. So:

| | |
|---|---|
| `delta` | never negative, because a falling counter is not negative deadlocks |
| `counter_reset` | set when the counter fell, so the timeline admits the discontinuity |
| | |
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
