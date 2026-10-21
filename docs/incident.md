# incident: when the queue will not fit on a screen

**For: someone on call, right now, past the point where `lock_tree_text()` is enough.** You can see
the tree and you cannot read it, or the root is a transaction with no session attached to it. Start
with the [incident card](../README.md#the-incident-card) if you have not already.

```
-- too many sessions to print: one row per root, ranked
SELECT * FROM lock_tree_summary();

-- the same, one row per waiter, so you can see who is behind whom
SELECT * FROM lock_tree_wide();

-- which query is costing the most time, and which application
SELECT * FROM lock_tree_statements();
SELECT * FROM lock_tree_duration_by_application(interval '1 hour');
```


## When the queue is too wide to read

A tree is one row per session, which is the right shape for one incident and the wrong shape for
a database having six at once. `lock_tree_text_short()` helps by abbreviating, and stops helping
at several hundred lines. `lock_tree_wide()` aggregates instead:

```sql
SELECT * FROM lock_tree_wide();
```

<!-- illustrative: written by hand. scenarios/s4 prints a real wide queue; this is a short version of it. -->

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

Every windowed function takes a `since` and seeks rather than scanning, so the cost tracks the window
you asked for and not the size of the history. On a seven day history of 1.2 million rows and 264 MB,
measured with `make bench-history`:

```sql
SELECT * FROM lock_tree_duration(interval '1 hour');        -- not interval '7 days'
SELECT * FROM lock_tree_duration_by_application(interval '1 day');
```

The seven day figures are still the slowest reads in the extension, because seven days of samples is
genuinely 60,481 instants and 1.2 million rows of work. Three ways of making that cheaper were built
and measured, and none of them helped: [the roadmap](roadmap.md#the-whole-window-duration-read-measured-rather-than-assumed)
has the numbers, including the one that made it twice as slow.

**Only the functions that read the history are ever slow.** Everything that reads the live tree is
milliseconds whatever the history holds: against the same 1.2 million row fixture,
`lock_tree_statements()` and `lock_tree_text()` each come in under 20 ms and `lock_tree_roots()` under
5 ms. Those are given as bounds rather than exact figures on purpose, because they move a little
between runs and the point is the order of magnitude, not the decimal.
`make bench-history` prints the two groups separately so you do not have to know which is which.

**If you stored these numbers anywhere.** `blocked_sessions_peak` and `sessions_total` were one too
high per sample until 0.15, because the root-to-waiter join matched each root to itself: a root
blocking three sessions reported four. The changelog has the entry.

### Three columns that are easy to get wrong

A root's **identity** and the waits it **caused** are recorded on different rows. `query_id` is on the
root row, `wait_age` is on the waiter's, so the three columns that come out of the join are:

| | |
|---|---|
| `longest_wait` | the longest wait this query caused |
| `blocked_sessions_peak` | the peak number of sessions behind it at one instant |
| `sessions_total` | that peak, summed over the instants it was the root |

Which is: root rows of a sample matched to the waiter rows of the **same** sample, on `root_pid` and
`root_object`. Until 0.13 the join did not do this and all three were wrong, so a query written against
an early release may have been reading a bug rather than a fact. The changelog has the entry.

### One hazard, if you are scheduling the sample

Samples have to be separate statements, because `sampled_at` is `statement_timestamp()`. A loop of
samples inside one `DO` block collapses onto a single instant and the rows look healthy while the
gaps between them are not there. That page has the two forms and the test that measures it:
[One hazard worth knowing before you schedule anything](history.md#one-hazard-worth-knowing-before-you-schedule-anything).

## A blocker with no backend

A prepared transaction holds its locks until `COMMIT PREPARED` or `ROLLBACK PREPARED`, and it has
no session for the whole of that time. `pg_stat_activity` has no row for it, and `pg_locks.pid` is
`NULL` for every lock it holds.

```sql
SELECT gid, prepared, owner FROM pg_prepared_xacts;
```

This is the one thing the usual recursive query cannot do at all, because it walks
`pg_blocking_pids()` and there is no pid to walk to. `pg_lock_tree` reports it as root pid 0, and
its suggested action is `ROLLBACK PREPARED` rather than a `pg_cancel_backend(0)` that could never
have worked.

### Two of them are two roots

`pg_blocking_pids()` reports the blocker as `0` for **every** prepared transaction, and there is no
backend to ask for its pid. So the pid alone cannot identify a prepared root: three of them all look
like pid 0, and anything that groups on the pid merges them into one row and reports a root that
holds four sessions when nothing holds four sessions.

**Group by the object, not the pid.** That is what `root_object` is for, and it is why
`lock_tree_summary()` counts roots by `(root_pid, root_object)` rather than by pid:

<!-- illustrative: written by hand, to make the point about pid 0. scenarios/s7 prints the real thing. -->

```
 three prepared transactions and four waiters, grouped by pid alone

 root_pid | blocked_sessions
        0 |                 4        <- one row, and nothing holds four sessions
```

The same incident, grouped by pid and object:

<!-- illustrative: written by hand, the same point as the table above it in the grouped form. -->

```
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

See `scenarios/s7_prepared.sql`, which builds three at once and prints both figures for the same
incident, so the comparison is measured rather than remembered.

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
  who each one is actually stuck behind, and `lock_tree_roots()` offers a cancel for each. Cancel
  **one** member and re-run the tree: breaking one wait frees the cycle, and cancelling every member
  rolls back transactions that did not have to be rolled back.
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
