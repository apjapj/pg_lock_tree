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
  [`lock_tree_sample()`](alerting.md#choosing-an-interval) scheduled, and neither will invent figures from a
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
