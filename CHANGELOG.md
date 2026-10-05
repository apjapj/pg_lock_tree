# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.10'`
selects a release.

## 0.13 (2026-10-05)

0.13: the aggregation a page actually needs

Three columns 0.12 could not get right, and the aggregation that answers the question a page asks.

### The bug: a root's identity and the waits it caused are on different rows

0.12's lock_tree_duration() reported three columns that could not be right. query_id is on the root
row. wait_age is on the waiter's. The 0.12 aggregates grouped by query_id and read wait_age off
those same rows, so:

| | 0.12 returned | why |
|---|---|---|
| longest_wait | always NULL | the rows carrying a query_id carry no wait on them |
| blocked_sessions_peak | always 1 | it counted ROOT rows per query per sample, and there is exactly one root row per query per sample |
| sessions_total | a second copy of samples | that same 1, summed over the instants |

Measured on a root blocking three sessions across three samples: 0.12 reported
blocked_sessions_peak = 1, sessions_total = 3, longest_wait = NULL.

One join fixes all three, the root rows of a sample matched to the waiter rows of the SAME sample on
root_pid and root_object. The object is part of the match for the same reason it is half of
lock_tree_alert's primary key: pid 0 is every prepared transaction at once, so matching on pid alone
would credit one prepared root's waiters to another.

Three columns, three column names, three documented meanings, all unchanged. They now return what
the documentation has always said they return.

### lock_tree_duration_by_application(since interval DEFAULT '7 days')

NOT lock_tree_duration() summed by application, and the difference is the whole point.

A batch job holding the queue for ten minutes will hand the queue from one statement to another
while it does it, because that is what a fixed script does. Say its statement 1 is the root at t0 and
its statement 2 is the root at t1:

    per query         both gaps DISCARDED: neither statement was the root at both ends
    per application   the gap COUNTS: the application was holding the queue at both ends

So summing the per-query figures reports the time an application spent blocking MINUS every
handover. Measured on a six-sample incident with one handover: the per-query sum was 4.028 seconds
where the application had actually held the queue for 15.368. A service that blocked forty sessions
for a quarter of an hour can be reported as having cost two seconds, and nobody notices, because the
number is small and plausible.

That is why the gap arithmetic is done again on (sampled_at, application_name) rather than
aggregating the per-query output. Everything else is identical, including the same conservatism: a
gap where the APPLICATION was not at the far end is discarded, and the interval after the last sample
is never counted.

An empty application_name is reported as its own row rather than filtered. A blocker that never
called SET application_name is one of the findings you are looking for, and dropping the row would
hide exactly the thing worth noticing.

### The two figures are not always ordered the same way

query_id identifies a STATEMENT, not who ran it, so two services running identical text share one
query_id. That inverts the comparison, and the README explains both directions:

  a handover between DIFFERENT statements inside one application: per-application is LARGER, because
    the per-query rule discarded the handover gap

  the SAME statement handed between two applications: per-query is LARGER, because the statement is
    identical on both sides so every gap has it at both ends, while the per-application rule discards
    that gap as attributable to neither service

Neither is wrong. test/17 pins both directions, because a test that only pinned the first would
have let the second look like a bug.

### WHY CREATE OR REPLACE AND NOT DROP

The signature and every column type are unchanged, so CREATE OR REPLACE FUNCTION is permitted: the
restriction is on changing a return type, not on changing a body. It also keeps the OID, which keeps
GRANT EXECUTE ON FUNCTION lock_tree_duration(interval). Verified: a role granted EXECUTE before
ALTER EXTENSION ... UPDATE still has it after. DROP and CREATE would have silently revoked an
operator's grant on a function that did not change shape, which is a worse failure than the bug being
fixed.

Nothing is dropped, no view is re-created and no rewrite lock is taken.

### check-alert.sh --explain now explains a cleared payload

0.12 added the resolution notice but left --explain reading it as an onset, which printed "Run these,
in this order" and pg_terminate_backend on a pid that had already gone. It now dispatches on the
event key and explains the two differently on purpose: an alerting payload is a question and the
output is what to run; a cleared payload is a statement about the past and the useful output is what
the incident WAS, plus five queries for looking it up.

The alerting branch is unchanged apart from one added line reporting the event, so a payload with no
event key at all (everything sent before 0.12) still explains as an onset, which is the only place
in the script where an absent key is read as a present one.

Two bugs in the generated SQL, found by executing it rather than reading it:

  json.dumps emits DOUBLE quotes, which PostgreSQL reads as an identifier, so every query it
    produced was a syntax error waiting to be pasted. Replaced with a sql_str helper that emits
    single quotes and doubles any inside. Verified by running all five generated statements.

  FROM lock_tree_incidents(), unnest(applications) AS u names the TABLE u, not a column u, so
    GROUP BY u failed. The column alias AS u(application) is what makes it a column.

### A test bug that was an arithmetic bug

The 0.12 test asserted sum(gaps) + sum(gaps_excluded) equals a hardcoded instant count. It passed,
for the wrong reason twice: gaps are counted PER QUERY, so a gap where two queries were both rooted
is counted once for each, and the constant happened to be the sum rather than the count. 0.13's test
computes the expectation from the samples instead.

Three more of my own, all found by this file failing:

  count(*) over the function's rows, where sum(gaps) was meant. One row per application, so it is
    always 1.

  Summing EVERY per-query figure and comparing it against ONE application. Different questions.
    Now joined through query_ids so both sides are the same statements.

  A fixture where both applications ran the identical LOCK TABLE app_t2, so they shared a query_id
    and lock_tree_duration() correctly merged them. The fixture now uses three tables, and the shared
    query_id case is pinned deliberately rather than avoided.

And one design point the second of those taught me: a gap is keyed on the application being rooted
at its NEAR end, so a single isolated sample is not a blocker by this measure at all. Two instants
are needed before a root appears. Same rule that discards the trailing interval everywhere else.

### Also

- test/17_duration_by_application.sql, 22 assertions.
- 314 tests total, green on PG 14, 15, 16, 17, 18 and 19beta4.
- scripts/lint-docs.sh needed no change: it already recognised FUNCTION.

## 0.12 (2026-10-05)

Two additions, both about the same thing: turning what the extension already records into something
an operator can act on. A real blocking-time figure instead of a sample count, and a way to find
out that an incident is over.

### `lock_tree_duration(since interval DEFAULT '7 days')`

`lock_tree_history_statements()` reports **session-samples**: one unit per blocked session per
sample. That is a count of observations, and the 0.7 documentation says so plainly. It is not a
duration, and there is a case where being precise about that matters.

The same six-second incident, sampled twice:

| | session-samples | gap-summed time |
|---|---|---|
| 3 samples over 6s | 3 | 00:00:06 |
| plus 6 more over the next 6s | 9 | 00:00:06 |

One figure tracked elapsed time. The other tracked how often anybody looked. So ranking statements
by it means ranking them partly by your cron entry, which is a thing you would have to notice and
then explain to someone.

`lock_tree_duration()` sums the **gaps between sample instants**. While a query was the root at both
`t0` and `t1`, it was the root for the whole of `t0` to `t1`, and both of those are instants at which
it demonstrably held the queue up. That is a measurement rather than an interpolation, which is the
property the sample-count version lacks.

Deliberate choices, all visible in the output:

- **A gap counts only where the query was the root at both ends.** A gap whose far end has a
  different root is discarded rather than apportioned. Nobody observed when the handover happened,
  so any split of it would be invented. `gaps` and `gaps_excluded` report both counts.
- **The interval after the last sample is never counted.** A chain still standing when the sampler
  last ran contributed time nobody measured. This is a lower bound on the truth and it says so,
  rather than presenting a figure whose provenance is unclear.
- **`blocking_seconds` is `numeric`, not `interval`.** A duration in seconds is what a reader
  compares across queries and against a budget, and a fractional second survives.
- **`applications` is an array, not a name.** One query id can be seen under more than one
  application across a week.

`lock_tree_history_statements()` is unchanged and still there. It is the cheaper question, it needs
no gap arithmetic, and for "which query blocks the most sessions" it is the right answer. Both are
worth having; they are not substitutes.

### A hazard, measured rather than only described

While working this out I found that samples inside a single statement are invisible as elapsed time.
`sampled_at` is `statement_timestamp()`, fixed for the duration of a statement, so:

```sql
DO $$ BEGIN FOR i IN 1..4 LOOP PERFORM lock_tree_sample(); PERFORM pg_sleep(1); END LOOP; END $$;
```

writes four samples' worth of rows and records **one** instant. Four seconds of incident, not
traceable. This is not new behaviour: 0.4 fixed a related bug where `clock_timestamp()` capped
`peak_sessions` at 1, and `statement_timestamp()` was the fix. That fix is what a cron entry
depends on and what a `DO` loop defeats.

The rows look healthy unless you count instants rather than rows, so the README now shows both
forms and `test/16_duration_resolved.sql` pins it with the measurement: a `DO` block writes rows,
adds fewer than four instants, and `lock_tree_duration()` does not absorb the loop. The safety
property that matters is that four rows in one instant produce no gap and therefore no invented
duration.

### `lock_tree_notify_resolved(channel, min_blocked, min_depth, min_wait)`

`lock_tree_notify()` says when something starts getting worse and then says nothing. That was
deliberate in 0.6 and it is right for a pager. It is wrong for the person who was woken up at 03:00
and now has no way to find out whether to go back to bed.

This raises one notification per root that **had alerted** and has since left the tree, with `event`
set to `"cleared"` in place of `"alerting"`, then forgets the stored state so the next incident
alerts from the start rather than escalating against a high-water mark from a previous one.

- **A root that never alerted produces nothing.** A resolution notice with no matching alert is
  noise. The function reads the rows it is about to delete, so it cannot report one it did not send.
- **It keys on the same state and the same policy string as `lock_tree_notify()`.** Pass both
  functions the same thresholds or this will resolve alerts that were never sent, which is the one
  way to make it actively misleading.
- **A separate function, not a parameter.** An `alerting`/`cleared` pair on one channel is what a
  consumer wants, but whether an incident ending is worth a message is a property of your rota
  rather than of this extension, and someone who never wants it should not be able to switch it on
  by accident through named notation.
- **Backwards compatible.** A consumer written against 0.6 that ignores unknown fields is
  unaffected.

### One payload change to `lock_tree_notify()`

The onset payload gains one key, `event`, set to `"alerting"`.

It had none before, which was fine until there were two kinds of notification on the same channel
and a consumer had to tell them apart. The alternative was inferring an onset from the **absence** of
a key, which is the sort of contract that breaks silently. It was found by the first run of the
updated [`scripts/check-alert.sh`](scripts/check-alert.sh), which asserted the first payload
said
`"alerting"` and was wrong, because nothing had ever put it there.

The one behaviour change in 0.12. It is additive and safe: JSON consumers read by key, every
documented key keeps its meaning, and a listener that ignores fields it does not recognise is
unaffected. It arrives as `CREATE OR REPLACE FUNCTION`, which is permitted because the restriction
is on changing a return type rather than on changing a body, and this function has no `OUT` list.
In place it takes a lock on one catalog row and nothing else: no table, no view, and none of the
alert state, which is data.

### [`scripts/check-alert.sh`](scripts/check-alert.sh), restructured

Proving the resolution notices meant proving that a `cleared` payload really arrives, and adding
that turned up two things in the existing script.

**The silence check was passing for the wrong reason.** It built the chain in one `psql`
invocation and checked for silence in a later one. A `psql` session that exits takes its dblink
backends with it, so by the time the later invocation ran, the chain was gone,
`lock_tree_notify()`'s own sweep had already deleted the stored alert row, and "0 returned" was
being read from a tree with nothing in it. That also left nothing for
`lock_tree_notify_resolved()` to resolve, which is how a run reported zero cleared roots next to an
assertion demanding one.

**The listener slept through its own notifications.** `NOTIFY` is only delivered at a command
boundary, so the listener's single `pg_sleep(8)` held everything until it returned. That happened to
be long enough for the run and short enough to notice, and would have broken the moment the run got
slower. It now issues one statement per second through `\gexec`.

Both are fixed: one listener, and one session that holds the chain for the whole sequence. The
payload stream is asserted as a sequence, so exactly two payloads arriving, `alerting` then
`cleared`, is itself the silence check seen from the other end. A function that returned 0 while
still sending something is now caught.

Also fixed along the way: teardown disconnects the dblink connections rather than terminating them.
Terminating first kills the backend, and `dblink_disconnect` on a connection whose backend has gone
fails with `connection "ah" not available`, which aborted the script outright.

### `scripts/check-deadlock.sh --deadlock-timeout=INTERVAL`

The increment in `pg_stat_database.deadlocks` lands when the server breaks the cycle, which is
`deadlock_timeout` after the wait began. `scenarios/s6_deadlock.sql` raises it to 15s so the cycle
survives to be photographed, which put the counter and the cycle in two different places. Now the
parameter that separates them is a parameter, so the script proves both halves in one run:

```
$ scripts/check-deadlock.sh --deadlock-timeout=15s
  counter before the deadlock: 0
  deadlock_timeout for the two victim sessions: 15s, wait budget 45s
  both sessions are blocked on each other: that is a real cycle
  the cycle is visible in pg_stat_activity and the counter is still 0
  the counter moved, from 0 to 1
```

The middle line is the useful one. It is the state `s6` photographs, and it is the answer to the
question that sends people to the source: *I can see a deadlock but `deadlocks` has not moved, is
something broken?* Nothing is broken. It moves at `deadlock_timeout` and not before. Omit the
parameter to use the server's default (1s), or pass `2s` to break it promptly. The setting is
applied to the two victim sessions only; `postgresql.conf` is not touched.

### Also

- `test/16_duration_resolved.sql`, 19 assertions.
- 292 tests total, green on PG 14, 15, 16, 17, 18 and 19beta4.
- `scripts/lint-docs.sh` gains checks for both objects. It needed no change to its own matching:
  it already recognised `FUNCTION`, and [`scripts/check-deadlock.sh`](scripts/check-deadlock.sh) already parsed.

Nothing is removed or renamed. Both objects are new, so the update from 0.11 adds nothing and takes
no rewrite lock: `pg_lock_tree--0.11--0.12.sql` is `CREATE FUNCTION` twice.

## 0.11 (2026-10-11)

The two things that were wanted when partitioning `lock_tree_history` was proposed, because
partitioning turned out not to be available.

### Why it is not available, measured rather than assumed

PostgreSQL has no `ALTER TABLE ... SET PARTITIONED BY`. Converting a table means creating a new
partitioned table, copying the rows, and swapping. The swap cannot be done from outside the
extension, because the table is a member:

```
DROP TABLE lock_tree_history
ERROR:  cannot drop table lock_tree_history because extension pg_lock_tree requires it
```

The same restriction that applies to the view. The only place `DROP TABLE` is permitted is **inside
an extension update script**, so the copy would happen unattended during
`ALTER EXTENSION ... UPDATE`, on however many rows the user happens to have, holding whatever locks
that takes, with no way to stop it half way. That is not a change to make on someone's behalf in a
script they did not write, so it is not offered. The README says what to do instead.

### What replaces it

The problem partitioning was meant to solve is real: `lock_tree_prune()` is one `DELETE`, which on a
large table takes a long time, holds its locks for all of it, and leaves the free space behind for
`VACUUM` to find.

**`lock_tree_history_size()`** answers the question partitioning was proposed to answer, without it.
"Is this table going to fill the disk" is a question about a rate, and a rate needs two samples and
the interval between them. It reports rows, samples, `pg_total_relation_size`, the oldest and newest
sample, the observed interval, bytes per day, and `days_to_1gb`, which is the number to alert on.

Three details it does not get wrong:

`pg_total_relation_size` rather than a hand-rolled sum of `pg_relation_size`, because the sum misses
TOAST and the free space map, and the total is what the disk is charged.

The observed interval is `(span) / (gaps)`, not the average of the intervals. Averaging weights a
long gap the same as a short one; dividing the span is the thing that actually has to be divided.

An unsampled database gets `NULL` for every rate column, not a large number invented from no data.
The test asserts all three.

**`lock_tree_prune_batched()`** is a **procedure**, and that is the entire reason it works: only a
procedure can `COMMIT`, and a batched prune that cannot commit between batches still holds
everything. Rows are selected by primary key rather than by `OFFSET`, because `OFFSET` is
`O(rows skipped)` and the tenth batch would walk past everything already deleted.

```sql
CALL lock_tree_prune_batched(interval '7 days', 20000);   -- fine
BEGIN; CALL lock_tree_prune_batched(interval '7 days'); END;   -- ERROR
```

It checks for a transaction block **before deleting anything**, so wrapped in one it fails having
removed nothing, rather than part way through with half the table gone. That ordering is the useful
part; the error PostgreSQL raises is `invalid transaction termination`, which does not say why, so
the `COMMENT ON` and the README both explain it.

`lock_tree_prune()` is unchanged and still there. A batched prune you cannot interrupt is worse than
an unbatched one in some situations, so the procedure is opt-in.

### Two things that could not be done the obvious way

**Checking for a transaction block cannot be wrapped in an exception handler.** The first version
raised `COMMIT` inside a plpgsql block with an `EXCEPTION` clause, to turn the failure into a
readable message. A block with an `EXCEPTION` clause runs in a **subtransaction**, and `COMMIT` is
never permitted in one, so the check failed every time rather than only inside a transaction block.
It refused to work outside a transaction block too. The check is a plain `COMMIT` now, and the error
is explained in prose rather than caught.

**`throws_ok` inside pgTAP reports `0A000`, not `2D000`.** `throws_ok` runs the statement in a
subtransaction, and there the refusal is "EXECUTE of transaction commands is not implemented".
Called inside a real `BEGIN` block at the top level it is `2D000` "invalid transaction
termination". Same refusal, different wording, because a subtransaction and a transaction block are
different things to PostgreSQL. The test asserts the one it actually observes and says why.

### A test bug that was an arithmetic bug

`test/15_history_size.sql` asserts nothing was deleted when the `CALL` is refused. The first version
compared against a hardcoded row count, and was wrong twice: once by forgetting the 60 rows left by
the fixture above it, and once by forgetting a row the setup had already used. The assertions are
now relative to the table at the moment of the check, which is the thing this file is about, so the
test should measure it the same way.

A stray `BEGIN;` with no `COMMIT` in the middle of the file put the whole rest of the psql script
into a transaction block, and the later `CALL` then failed with "invalid transaction termination" for
a reason that had nothing to do with what was being tested. `throws_ok` runs the statement inside its
own subtransaction, which is the right way to check it.

Verified: 273 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios; the 0.10 ->
0.11 upgrade against a populated history and the full `0.2--0.11` chain; the batched prune removing
rows in 6 batches of 7 out of 40 aged rows; demo, check-install, check-alert and check-deadlock.

## 0.10 (2026-10-04)

## 0.10 (2026-10-04)

Deadlocks, and an extension that finally reads its own history.

Two features. One table, one function and one column added; one function's return value gains a side
effect and one function's signature changes. Nothing existing is rewritten and no rewrite lock is
taken.

### Deadlocks: when, and not what

The extension could watch a deadlock happen and had nothing to say about it afterwards.

`pg_stat_database.deadlocks` has been there since PostgreSQL 13, so it is available on every version
supported here. Checked rather than assumed, since the version it was added is the sort of thing
worth being wrong about and the alternative is a function that fails at `CREATE EXTENSION` time on
the oldest version in the matrix.

`lock_tree_sample()` records the counter. `lock_tree_deadlocks()` reports when it moved: the
cumulative value, how far it moved, and the window total.

**It does not name the two statements, and nothing in SQL does.** The participants exist only in the
server log. What this gives is the timestamp, and that is the half that makes the log worth reading:
three deadlocks between 09:00 and 09:15 on a Monday is a deploy or a cron job, not a mystery. The
README has the `log_lock_waits` recipe and says plainly what the counter cannot do.

### Why the counter is sampled into its own table

This is the part worth understanding, and it is not tidiness.

`lock_tree_history` only has rows while something is **blocked**, and PostgreSQL resolves a deadlock
by killing one participant. So by the time the sampler runs, the cycle is over, the tree is empty, and
there is no history row to hang a counter on. Measured:

```
 the counter moved, from 15 to 16
 and nothing is blocked now, so lock_tree_history would record nothing at all
 a sample wrote no history rows, because the tree is empty
 and lock_tree_deadlocks() reports the move: delta = 1
```

A deadlock you did not happen to be looking at is exactly the one worth catching, and putting the
counter on `lock_tree_history` would miss all of them. `lock_tree_deadlock` is therefore one row per
sample, written whether or not anything is blocked.

### Counter resets

The counter can go **backwards**: `pg_stat_reset_shared('db')` sets it to zero. A naive delta is then
negative, which is not a number of anything. So `delta` is floored at zero, `counter_reset` records
that the baseline changed, and `total_in_window` sums only the deltas **after** any reset, so a reset
cannot quietly understate the window.

### Sampling advice now reads the history

`lock_tree_sampling_advice()` sized the interval from the queue at the instant it was called. A cron
entry at 3am on a quiet Sunday therefore recommended the finest interval, for a database that spends
every weekday morning with four hundred sessions waiting. The advice was not wrong about the
instant. It was answering the wrong question: the question is what the table has to carry, and the
table's size is set by the peaks.

It now takes a window, reads the peak out of the history, and uses the **greater** of that and the
live queue, so a queue that started after the last sample is not ignored. Both inputs come back as
columns (`observed_peak`, `live_blocked`) so the advice can be traced back to what it was based on.

The column is `look_back`, not `window`, because `WINDOW` is a reserved word and a column with that
name has to be quoted at every use and in every example that reads it.

### `lock_tree_prune()` clears both tables, and counts only one

It now deletes from `lock_tree_deadlock` as well. Its return value still counts **only** the history
rows, because it has returned a history count since 0.4 and every existing caller reads that number.
At a five second sample interval, counting the deadlock rows too would inflate it by a factor of the
sample rate, and a monitoring job that has been right for six releases should not start reporting
four orders of magnitude more than the table it watches. One call to remember rather than two is
worth the asymmetry. The deadlock rows are still deleted, and the decision is stated in the function
body as well as here.

### Where the end-to-end deadlock test lives, and why not in the suite

`scripts/check-deadlock.sh`, not a test file.

The increment lands when the server breaks the cycle, which is `deadlock_timeout` after the wait
began. Three separate attempts to observe that inside a single psql session all failed, each
differently and each instructive:

1. The deadlock was built from dblink connections belonging to the session that was also sampling.
   The two interfered and the deadlock was never observed at all.
2. Waiting on the counter is circular. The counter only moves once the server has acted, and it acts
   on a timer, so a bounded loop never sees the move and reports that nothing happened.
3. Waiting for the **cycle** first and then for the counter works, but only when the sample is a
   separate process.

`scenarios/s6_deadlock.sql` builds a real deadlock too, and it shows the counter being sampled. But it
raises `deadlock_timeout` to 15s so the cycle survives long enough to be photographed, which means the
increment lands long after that scenario has moved on. So the two live in different places, and the
scenario says so rather than showing an empty table and leaving the reader to guess.

`test/14_deadlocks.sql` covers everything that can be covered deterministically: that a sample on a
quiet tree still records the counter, that a delta is a subtraction and never negative, that a reset
is reported as a reset, and the history-derived advice.

### A fixture bug worth writing down twice

The advice fixture builds a history that peaked at 450 sessions, and the first version of it used
`clock_timestamp()` in the `INSERT ... SELECT`. That is volatile and evaluated **per row**, so all
450 rows got a `sampled_at` a few microseconds apart. The advice groups the history by `sampled_at` to
find the widest sample, and 450 groups of one session has a peak of 1. The fixture described a
database with no queue at all and the test failed for a reason that had nothing to do with the code.

This is the same trap that made `lock_tree_sample()` record a different `sampled_at` per row in 0.4,
which silently capped `peak_sessions` at 1. It is recorded here a second time because it looks like a
harmless choice of clock function and it is not: **any per-row timestamp in this table destroys the
only thing the history is for.**

### Also

- `pg_lock_tree--0.9--0.10.sql` drops and recreates `lock_tree_sampling_advice()`, because
  `CREATE OR REPLACE FUNCTION` refuses a changed OUT list and it returns a table.
- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.10.sql`.

Verified: 250 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios; the 0.9 -> 0.10
upgrade against a populated history and the full `0.2--0.10` chain; [`scripts/check-deadlock.sh`](scripts/check-deadlock.sh) observing a
real deadlock move the counter with nothing blocked at the sample; demo and check-install.

## 0.9 (2026-10-04)

## 0.9 (2026-10-04)

Alerting learns to escalate on age, and a payload learns to explain itself.

Two changes, both in the alerting added in 0.6 and 0.7. No signature changes anywhere, so nothing is
dropped and the update path is one `ALTER TABLE` plus two `CREATE OR REPLACE FUNCTION`.

### Escalation watched width and depth but not age

Through 0.8 `lock_tree_notify()` escalated on two things: a root blocking more sessions than it
ever had, and a root deeper than it ever had. It did not escalate on **how long anyone had been
waiting**. So a chain that sat at forty blocked sessions while the longest wait went from five
minutes to thirty never notified again.

That is not an edge case, it is the ordinary shape of an incident that is getting worse. Nothing
about it is sudden, so nothing triggers an edge-triggered rule.

### Why the wait escalates by doubling and not by growing

A wait is not an edge, it is a slope. It grows every second, so the obvious comparison, "is the
longest wait longer than it was last time?", is **true on every sample**, and the function would
notify sixty times an hour. That is the exact noise `lock_tree_alert` was introduced to prevent,
reached by a different route.

So the comparison is against **the wait recorded at the last notification**, and fires only once
that wait has doubled:

```
 30s    1m    2m    4m    8m    16m   32m
  |     |     |     |     |      |      |
  +-----+-----+-----+-----+------+------+
```

Seven notifications for a thirty-two minute incident, each saying it is roughly twice as bad as
the last. Seven is deliberate: few enough that nobody learns to filter the channel, many enough
that a thirty-minute queue does not sit at the same reported severity for half an hour. It is the
same reasoning as exponential backoff, applied to whether to wake someone.

**It only applies when `min_wait` is set.** An operator who passes `min_wait => NULL` has said they
do not want to be paged on wait age, and that is honoured even when the wait is enormous. A second
page about a slow queue you did not ask about is how a channel stops being read.

### The bug the test found, twice

**Doubling zero is zero.** `max_waited_at` starts at zero, so `longest_wait >= max_waited_at * 2`
is `longest_wait >= 0`, which is always true. The first measurement of this feature notified on
every single sample: the precise failure mode it was written to prevent. The fix is
`greatest(max_waited_at * 2, min_wait)`, so with nothing recorded the first escalation is the
operator's own threshold.

**`greatest()` ignores NULLs.** PostgreSQL's `greatest` returns the largest *non-null* argument
rather than propagating NULL, so `greatest(longest_wait, want_wait)` with `want_wait` NULL
returned the wait: with `min_wait` switched off, the row quietly recorded a wait for a criterion
that did not exist. It needs a `CASE`, not a NULL-tolerant aggregate. The assertion that found it
was "with `min_wait` off, nothing is recorded", which is the sort of test that looks pedantic until
it is the one that matters.

### [`--explain`](scripts/check-alert.sh), and why it needs no database

An alert arrives as a JSON payload with no instructions attached. The recipient has to know what it
means and what to run, at whatever hour it arrived.

```bash
[`scripts/check-alert.sh`](scripts/check-alert.sh) --explain '{"root_pid":0,"root_object":"AccessExclusiveLock on public.ledger", …}'
```

prints what the payload says, what it means, and the queries to run in order. It **needs no database
and no superuser**, which is the point: the first thing you do at 3am should not be something that
can fail because the database is the thing that is broken. `make explain-alert PAYLOAD='…'` is the
same thing.

It branches on `root_pid` rather than on the message text. A session root gets
`pg_terminate_backend` steps; a prepared root gets `ROLLBACK PREPARED` steps and an explicit
statement that `pg_cancel_backend(0)` returns false and warns that pid 0 is not a backend. That
branch is worth being careful about, because the two failures look identical on a dashboard and
need opposite remedies.

It also refuses to guess. A payload that is not JSON is reported as not JSON. JSON without a
`root_pid` is reported as probably not from this extension, which is the right answer for a
listener serving several kinds of message on one channel.

### Tests

`test/11_alert.sql` grows from 30 assertions to 48. The new phase builds a chain that **never gets
wider or deeper** and only ages, which is the isolation that makes the result mean something: with
a queue that is also growing, any notification could have come from any of the three rules. It
asserts onset once, silence, one notification at the doubling, silence again, that the two
high-water marks did not move, and that `min_wait => NULL` suppresses age escalation for as long as
you care to wait.

Two earlier assertions had to be re-scoped rather than fixed: `lock_tree_notify()` sweeps only the
policy it was called with, which is deliberate, so the alert table still holds the default-policy
rows from earlier phases. They now scope by root.

Verified: 221 tests green on PG 14, 15, 16, 17, 18 and 19beta4; [`scripts/check-alert.sh`](scripts/check-alert.sh) in both modes and
`--explain` against a session payload, a prepared payload, non-JSON, and JSON from elsewhere;
demo, scenarios and check-install.

## 0.8 (2026-10-04)

## 0.8 (2026-10-04)

Two bug fixes, no features. Both were found while measuring something else, and one of them is in
the view rather than in anything built on top of it.

### Two prepared transactions were one root

`pg_blocking_pids()` reports the blocker as `0` for every prepared transaction, because a prepared
transaction has no backend. So every prepared root had `root_pid` 0, and every place that grouped
on the pid merged them:

```
 0.7                                     0.8
 root_pid | blocked_sessions             root_pid | root_object                | blocked_sessions
        0 |                  4                   0 | AccessExclusiveLock on ledger  |                2
                                    versus         0 | AccessExclusiveLock on orders  |                2
```

Measured on PG 18 with three prepared transactions and four waiters. The left column is what 0.7
reported: **one root claiming four blocked sessions, held by nothing that exists**. `roots` was 1.
The right side is three roots with their own blast radii.

That is the number an operator acts on, and it was wrong in the one case this extension exists to
be better than the published recursive CTE at, since that CTE reports a prepared transaction as
nothing at all. Being right about a case rather than merely covering it is the whole argument, so
getting it right matters more than the count of features shipped.

**The fix is a new column, `root_object`.** It is what a prepared-transaction root is holding, and
it is `NULL` for a session root because `root_pid` already identifies that one. `root_pid` plus
`root_object` is the root's identity everywhere it matters: the view's walk, `lock_tree_roots()`,
`lock_tree_wide()`, `lock_tree_statements()`, `lock_tree_history`, and `lock_tree_alert`'s primary
key. On the functions it sits immediately after `root_pid` rather than at the end, because the two
are one identity and separating them by eight columns is how a reader ends up believing the pid is
enough.

The column is **always schema-qualified**, which is longer than necessary and deliberate.
`relation::regclass::text` qualifies only when the schema is not in the `search_path`, so the same
lock renders as `z1` in one session and `public.z1` in another. Measured: through the view it was
`z1`, and through `lock_tree_sample()`, which is `SECURITY DEFINER` and so runs with the owner's
`search_path`, it was `public.z1`. A value in a primary key cannot change with the `search_path`,
or an alert fires again for an incident it already reported. `waiting_for` still uses `regclass` and
is still path dependent, which is cosmetic there because nothing keys on it.

**Where the bug actually was, which is not where it looked.** The walk and the aggregates were
correct as written. The merge was in one line of `placed`, which used `SELECT DISTINCT ON (pid)`.
Both prepared roots have `pid` 0, so `DISTINCT ON (pid)` collapsed whichever sorted first, and the
survivor's identity was then used for the whole chain. It is now a `row_number()` partition with
pid 0 exempted, since pid 0 is a placeholder rather than a session.

Also worth stating plainly: **two prepared transactions holding compatible locks on the same
relation are still one root.** PostgreSQL cannot tell them apart either, `pg_blocking_pids()` gives
one `0` for both, so attributing a waiter to one of them would be a guess. Grouping by the object
rather than by the mode is the honest boundary.

### lock_tree_statements() could return two rows for one root

`pg_stat_statements` is not unique on `queryid` in practice. Measured on PG 18: a statement that
had run six times sat in **two** rows, with `calls` of 1 and 5, and the row-for-row join produced
two output rows for one root. Since the function is documented as one row per root, and its purpose
is grouping incidents by statement, a duplicate row is a duplicate incident.

It now aggregates that side in a `LATERAL` subquery: `sum(calls)`, `sum(total_exec_time)`, and the
mean recomputed from the sum rather than an unweighted average of means, which is wrong whenever
the buckets have different call counts, which is the entire reason they are separate.

This one was found because a container's `pg_stat_statements` had accumulated duplicate buckets.
It would have been found by a user sooner or later, and on a real system rather than a test one.

### Tests

`test/13_prepared_roots.sql`, 22 assertions: three prepared transactions, three roots, each waiter
under the root for the object it actually wants, `lock_tree_summary()` counting three where 0.7
counted one, `lock_tree_wide()` reporting one blocked session per root where 0.7 reported the
merged figure, history recording the objects, and alerting firing once per root and then staying
silent. Separate from `test/04_prepared.sql` rather than folded into it, because one prepared
transaction has always worked and the two case is a different failure.

`scenarios/s7_prepared.sql` now builds two more prepared transactions on fresh tables and
deliberately does **not** roll back the first, so all three are prepared at once. It prints the 0.7
figure computed from the same incident rather than quoted from memory.

### Three mechanical facts, all measured rather than assumed

`CREATE OR REPLACE VIEW` **can** append columns, but not drop or reorder them. That is why
`root_object` goes last on the view and second on every function. The view's seventeen existing
columns keep their names, types and positions.

`CREATE OR REPLACE FUNCTION` **cannot** change an OUT list at all: `cannot change return type of
existing function`. So the four functions that gained a column are dropped and recreated.
`DROP FUNCTION` of an extension member inside an update script is allowed, and the replacement is
re-added as a member automatically, so no `ALTER EXTENSION ... DROP` is needed. Both forms were
tried on a throwaway extension before being relied on.

`ALTER TABLE ... ADD COLUMN` with a non-volatile default is metadata-only at 11 and later, so both
new columns apply instantly whatever the size of the table. `lock_tree_history.root_object` has no
default and existing rows stay `NULL`, which is correct: a sample taken before the upgrade has no
recorded object. `lock_tree_alert.root_object` has `DEFAULT ''` because it joins a `NOT NULL`
primary key, and an empty string is the honest answer, since the value was never captured and every
existing row is a session root whose pid identifies it.

### A note on debugging this, since it cost real time

Four things went wrong in the harness and all four produced silence rather than an error, which is
the worst kind of failure:

- A shell loop over `$(docker exec psql -tA -c ...)` processed only the **first** prepared gid
  however it was written, so leftovers accumulated. `\gexec` in one psql session generates and runs
  every command server-side and cannot drop one.
- A fixture that took `BEGIN; PREPARE TRANSACTION` without a `LOCK TABLE` first holds no locks and
  blocks nobody, so the tree was silently empty.
- A scenario section that had `s7_stranded` holding `s7_t` then had a second prepared transaction
  try to lock `s7_t`, which waits forever with no error and no output. It hung rather than failed.
- A test run interrupted midway left a live `psql` that kept re-creating the state being cleaned
  up, so each cleanup appeared not to work.

The last three are all "no lock means no contention means nothing to see", which is the same failure
mode as the original bug: a test that measures nothing passes.

Verified: 203 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios with `s7` now
showing three prepared roots against the published CTE's zero; the 0.7 -> 0.8 upgrade against
populated `lock_tree_history` and `lock_tree_alert` tables, and the full `0.2--0.8` chain; demo,
check-install and check-alert.

## 0.7 (2026-10-04)

Per-query blocking time over the sampled history, and an eighth scenario for the wide case.

Everything from 0.6 is unchanged except `lock_tree_history`, which gains a `query_id` column and
an index. The column is added with `ALTER TABLE ... ADD COLUMN`, which is metadata-only: no rows
are rewritten and no rewrite lock is taken, so the upgrade applies instantly whatever the size of
the history.

### Added

- `lock_tree_history.query_id`: the session's own `pg_stat_statements` query id, recorded per
  sampled row. The index over it is **partial**, because the column is NULL on every waiter row and
  an index over mostly-NULL keys is mostly wasted space.
- `lock_tree_history_statements(since interval DEFAULT '7 days')`: per-query blocking time from
  the samples, worst first. For each root query id: how many blocked sessions it held up across
  all samples, over how many samples, when first and last seen, the deepest chain and longest wait
  under it, when that worst wait happened, and which applications were involved. This is the
  question that gets a fix merged rather than a workaround. `lock_tree_statements()` answers it
  for the chain in front of you; this answers it for the month.
- `scenarios/s8_many_roots.sql`: five blockers at once, 30/18/10/5/3 waiters across them, 71 rows
  of tree reduced to 5 rows by `lock_tree_wide()`. `s4` covers a wide queue behind a *single*
  root, which is the shape the abbreviation work targeted; a queue that is wide *and* has several
  heads is the case the aggregate exists for, and it had no scenario.
- `test/12_history_statements.sql`, 17 assertions.

### The unit is session-samples, and that is not the same as seconds

`blocked_sessions` here counts each blocked session once per sample it was blocked in. A session
blocked for 60 seconds at a 10 second sample interval contributes six, not sixty.

That is deliberate. It is a higher bound on precision, not a lower one on importance: the number
rises in proportion to the sampling rate, so the **ranking** between statements is stable and the
absolute figure is not. What to read is which statement is at the top, not what the top number is.
The test asserts this by dividing `blocked_sessions` by `samples` and checking the result is the
average queue depth rather than a duration.

### Only roots carry a query_id, so this is per blocking query

A query blocked on a lock has no `query_id` for as long as it is blocked, and gains one when it
completes. Same finding as `lock_tree_statements()`, and here it decides what the history can
record: root rows only.

The join is on each row's **own** pid rather than on `root_pid`. Joining on `root_pid` was the
first attempt and it propagated the root's query id down the whole chain, so every waiter looked
like it was running the blocking statement, which is the normal case and would have made the
totals wrong rather than merely incomplete. `test/12_history_statements.sql` pins the property
directly: no waiter row carries a query id, every root row does.

Existing history rows keep a NULL `query_id` and are not backfilled. The value was never
captured, and inventing one from the stored query text would produce a queryid matching nothing in
`pg_stat_statements`.

### Deliberately does not reference pg_stat_statements

`lock_tree_history_statements()` references no optional module at all. The history carries
`query_id` and the totals are pure aggregation over a table this extension owns, so it stays plain
SQL and parses anywhere. Joining the statement text back in is one line for whoever has the module
loaded, and the `COMMENT ON` says so. This is the opposite choice to `lock_tree_statements()`,
which must be plpgsql precisely because it does need the module.

### Bugs found while building the eighth scenario

Five, all in the new scenario, all found by running it:

- Roots were selected with `WHERE app IS NOT NULL`, but every waiter has an `application_name`
  too, so all 71 sessions were selected and the loop tried to take a lock on a waiter's
  connection. Filtering on the table name, which only roots have, is the right test.
- Two `send_query` calls per waiter failed with "another command is already in progress": dblink
  allows one in-flight command per connection. One statement carrying both the `SET` and the
  query, as `s4` does, is the fix.
- The distribution came out 14/13/13/13/13, nearly a tie, which makes the ranking the aggregate
  exists for look like it does nothing. Now 30/18/10/5/3.
- That fix then put all 66 on one root: a `DECLARE`d loop variable named `i` shadowed a record
  field of the same name, so the comparison read NULL and every waiter fell through to the
  `ELSE` branch. Reference the record field explicitly.
- The scenario printed "no coverage block" with all the numbers visible, because the other seven
  scenarios set `\pset border 2` and [`scenarios/run.sh`](scenarios/run.sh) requires the leading pipe to parse the
  row. Absent, the awk matched nothing and the summary reported a missing block rather than a
  missing border setting.

Two more elsewhere: `SELECT h.* FROM lock_tree_history` in `test/07_history.sql` became ambiguous
once the new column collided with `p.pid` from its join, so the columns are now named; and the
sample's `INSERT` needed `query_id` in its column list, since the select list had one more
expression than the targets.

Verified: 181 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios with `s8` at
66 sessions across five roots; the 0.6 -> 0.7 upgrade and the full 0.2 to 0.7 chain; demo,
check-install and check-alert.

## 0.6 (2026-10-04)

Alerting. Everything from 0.5 is unchanged, columns and all. The update path is additive: a table
and three functions, nothing altered, replaced or dropped.

History records what happened and `lock_tree_summary()` says whether anything is happening now.
Neither tells anyone. `lock_tree_notify()` closes that gap by raising a `NOTIFY` when a chain is
bad enough to be worth waking someone for.

Deliberately not included: anything that pages. Wiring a channel to a pager is a policy decision
that belongs to whoever runs the system, and the payload is JSON so that whatever you connect can
parse it without knowing anything about this extension.

### Added

- `lock_tree_notify(channel, min_blocked, min_depth, min_wait)`: raises a `NOTIFY` per notable
  root and returns how many it raised. **Zero is the normal, healthy result**, and it is the value
  worth watching.
- `lock_tree_alert`, a table of what has been alerted on: per channel, per threshold set, per
  root, with high-water marks. This is what makes the function notify once per incident instead of
  once per sample.
- `lock_tree_prune_alerts(older_than interval)`: forgets state orphaned by a restart or a retired
  channel. Not load-bearing; `lock_tree_notify()` maintains the table otherwise.
- `lock_tree_sampling_advice()`: a suggested interval for the sample cron entry, given how many
  sessions are blocked, with the reasoning. The cost of a sample is one row per blocked session,
  so a wide queue argues for a wider interval.
- `test/11_alert.sql`, 30 assertions: onset, silence, escalation, recovery, relapse, thresholds,
  and the refusal. Most of them assert a return of zero, which is the part worth testing.
- [`scripts/check-alert.sh`](scripts/check-alert.sh) and `make check-alert`: builds a chain, notifies, and reads the
  notification back from a **separate listening client**. A script rather than a test file because
  psql prints notifications to stdout and a TAP assertion cannot see stdout, so the delivery path
  needs a real second client.

### The design decision worth knowing about

It does not notify on every sample. A job that did would turn a two-minute incident into twelve
notifications, and everyone would learn within a week that the channel is noise, at which point
the one alert that mattered gets filtered along with the rest. A diagnostic tool that cries wolf
is worse than a silent one, because it costs you the thing the tool was for.

So it notifies on **onset** and on **escalation**, and stays quiet while a chain sits at the same
severity. Escalation is measured against high-water marks rather than the previous sample, so a
queue wobbling between 40 and 12 sessions notifies once rather than twice a minute, and a queue
dropping from 40 to 12 is recognised as getting better rather than re-alerting.

Thresholds are arguments, not settings, and there are no meaningful defaults. At least one must be
on, and all three off is refused with an error rather than quietly given a plausible value. A root
alerts if it meets **at least one** criterion that is switched on, because a queue can be bad in
ways unrelated to each other: a hundred sessions waiting one second is not an incident, and two
sessions waiting an hour is.

### Two design bugs the tests found

**Alert state was keyed by channel and root alone**, so two different alerting policies sharing a
channel cleared each other's state and each re-alerted on every alternate sample. A test that
alternated thresholds saw both roots fire twice when only one had actually got worse. The state is
now keyed by channel, threshold set and root.

**State was never cleaned up for a root that left the tree.** The per-root loop iterates over
`lock_tree_wide()`, and a root whose waiters have all gone has no edges and therefore no row
there: it simply vanishes. So the loop never saw it, never deleted its row, and the table grew
one row per root ever seen, all of them pids that will never be reused. There is now a sweep after
the loop. A test asserting the table empties on recovery is what caught it.

### Requirements, since most people will not know these

Documented at length in the README, because they are the things that make alerting not work:

- `NOTIFY` needs nothing at all. No extension, no `shared_preload_libraries`, no restart.
- **Something has to be listening, or the notification goes nowhere.** PostgreSQL does not queue
  notifications for absent listeners, so a `NOTIFY` raised with no listener is discarded. If your
  listener is down you get no alerts and no record that you got none.
- `lock_tree_alert` must be writable by whoever runs the sampler, and `lock_tree_notify()` is
  deliberately **not** granted to `PUBLIC`: it decides what is important enough to page someone,
  which is not a decision an arbitrary role should make.
- Alerting inherits the sample interval. Alerting every 10 seconds learns in 10 seconds at ten
  times the write cost.

### Also

- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.6.sql`.
- `scripts/check-install.sh` verifies the three new functions and reports whether
  `lock_tree_alert` is reachable.

Verified: 164 tests green on PG 14, 15, 16, 17, 18 and 19beta4; the 0.5 -> 0.6 upgrade and the
full chain; demo, seven scenarios, check-install, and `scripts/check-alert.sh` delivering a JSON payload to
a real listener.

## 0.5 (2026-10-04)

The wide case, and the cost of the blocking query. Everything from 0.4 is unchanged, columns and
all. The update path is additive, so there is nothing to migrate; PostgreSQL chains
`0.2--0.3--0.4--0.5` itself and `pg_extension_update_paths` confirms it.

### Added

- `lock_tree_wide()`: one row per root rather than one per session, with how many sessions each
  root blocks, the deepest chain under it, the longest wait, the distinct wait events, and what
  they are waiting for. On a 57-row two-root queue that is two rows instead of fifty-seven.
  `lock_tree_text_short()` made a wide queue narrower by abbreviating; that helps at sixty
  sessions and stops helping at six hundred, because the questions an operator actually has
  (which root is worst, how many sessions does it hold up, is anything a chain rather than a flat
  queue) need every line read to be answered.
- `lock_tree_summary()`: one row for the whole queue, for a dashboard cell or an alert
  condition. Returns zeros on a quiet database rather than no rows, so it can be used directly
  without a special case for "nothing is wrong".
- `lock_tree_statements()`: per root, what `pg_stat_statements` already knows about the query
  holding the lock. Normalised text, calls, mean and total time. This is the join that turns
  "pid 4821 holds a lock" into "this statement has run 40,000 times at 180ms mean", and the
  reason two incidents at 09:00 and 14:00 with different pids are recognisable as one problem.
- `test/08_wide.sql` (20 assertions): a 57-row two-root queue, with every number in the wide form
  checked against `lock_tree`. A summary that disagrees with the tree it summarises is worse than
  none, because it looks authoritative.
- `test/09_cost.sql` (6 assertions): the cost claim the README and the SQL header both make, now
  actually tested.
- `test/10_statements.sql` (11 assertions): `lock_tree_statements()` with and without
  `pg_stat_statements` loaded.

### The cost claim, pinned

`pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it only
for sessions already waiting on a heavyweight lock. That was asserted in two places and checked
in none, and a refactor dropping the `wait_event_type = 'Lock'` guard would have looked identical
in every other test while getting roughly ten times more expensive on a busy server.

The test measures a **ratio**, not a wall-clock ceiling: a view scan against a plain
`pg_stat_activity` read of comparable size, both timed inside one `DO` block. Absolute timings on
a shared CI runner are noise. Measured five times on an idle container a single view scan varied
between 133 and 174 microseconds, which would make any fixed threshold either flaky or so
generous it caught nothing. The ratio sat between 4.6 and 6.4 across those runs, so the ceiling is
50: loose enough for a loaded machine, tight enough to catch the regression it exists for.

The same file checks the guard's correctness consequence directly, which does not depend on timing
at all: a session is only reported as blocked if it is genuinely waiting on a lock, and a root is
never itself waiting.

### `lock_tree_statements()`: optional in both directions

`pg_stat_statements` needs to be in `shared_preload_libraries` to be readable at all, and its
failure mode is nasty: `CREATE EXTENSION` succeeds and then every read of the view raises
`pg_stat_statements must be loaded via "shared_preload_libraries"`.

A SQL function naming `pg_stat_statements` directly therefore fails at `CREATE EXTENSION` time on
a server without it, which would make an optional feature mandatory. This one is `plpgsql`, with
the join built as text and run through `EXECUTE` behind a `to_regclass` check. Without the
module it still reports every root and how much each blocks, with the statement columns empty, so
a dashboard querying it needs only one code path.

**It cannot enrich the waiters, and this was measured rather than assumed.** A query blocked on
a lock has a `NULL` `query_id` for as long as it is blocked and only gains one when it completes,
so the waiter side of the join is empty during exactly the moment anybody would want it. The root
is the opposite and carries a `query_id` throughout. That is fortunate rather than lucky, since
the root is the session anyone acts on. `test/10_statements.sql` asserts the limitation so it
cannot quietly become a claim the function cannot keep.

### Test harness

`pg_stat_statements` is now preloaded in the matrix images alongside `pg_cron`, so
`test/10_statements.sql` runs rather than skips on all six versions. Neither module is a runtime
dependency of the extension: it needs no `shared_preload_libraries`, and seven of the ten test
files run without either.

### Fixed

Nine bugs, all found by running things. Six in the new tests, two in the linter, one in the
demo:

- `test/08_wide.sql` compared an aggregate inside `WHERE`, which SQL forbids. Moved to `HAVING`.
- `sum()` over `bigint` returns `numeric`, and pgTAP's `is()` has no numeric/bigint overload.
- The wide test's teardown waited for the tree to empty without rolling the roots back first.
  The waiters were blocked on locks the roots held, so the wait simply timed out after ten
  seconds and the "quiet database" assertions measured a queue that was still stuck.
- A loop variable named `n` shadowed the `n` column of the dblink name table.
- `test/10_statements.sql` interpolated a `\gset` boolean into a dollar-quoted `DO` body. psql
  does not interpolate inside dollar quotes, so the block was a syntax error.
- The new images preload `pg_stat_statements` but do not create the extension, since it is
  per-database. The test skipped on all six versions and reported success. It now creates it when
  the library is loaded, and gates on `to_regclass` afterwards, which is the state a user who
  followed the documentation is in.
- `scripts/lint-docs.sh` rejected a correct conditional test file: it compared `skip(N)` against
  `plan(N)`, which only holds when `\if` wraps the whole file. When `\if` wraps part of it the
  arithmetic is `skip(N) == plan - unconditional`. Four further bugs in that same fix: an `\if`
  anchor that never matched because psql meta-commands carry arguments, an over-escaped grep
  pattern, an `if`/`fi` imbalance that made the whole script unparseable, and a check that ended
  up comparing against nothing at all.
- The demo's new history section sampled while the deadlock section's cycle was still running, so
  "nothing is blocked" reported two rows and contradicted itself.

Verified: 134 tests green on PG 14, 15, 16, 17, 18 and 19beta4 from cold-pulled registry images;
the 0.4 -> 0.5 upgrade and the 0.2 -> 0.3 -> 0.4 -> 0.5 chain; demo, all seven scenarios and
check-install.

## 0.4 (2026-10-04)

Adds history. Everything from 0.3 is unchanged: the view's columns and every function's
signature and output are byte-identical, and the update path is purely additive, so there is
nothing to migrate. `ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in
place; verified from clean 0.2 and 0.3 installs, and PostgreSQL chains `0.2--0.3--0.4` for you.

The motivation is the one limit nothing here could work around. Every other object reports the
present, which is exactly what you cannot read at the moment an incident is noticed: by then
`pg_stat_activity` has moved on and the tree is empty. History is opt-in and starts empty.

### Added

- `lock_tree_history`, a table of sampled trees, one row per session per sample so the shape of
  the chain survives. Indexed on `sampled_at` and on `(pid, sampled_at DESC)`, since an unindexed
  history table is one nobody can afford to query once it holds a day of samples.
- `lock_tree_sample()`: takes one snapshot, returns the number of rows written. **0** when
  nothing is blocked, rather than a row recording that nothing was blocked, so an idle server
  costs one `SELECT` and no storage.
- `lock_tree_incidents(max_gap interval DEFAULT '5 minutes')`: the history grouped into
  incidents, each with when it ran, peak sessions blocked, deepest chain, longest wait, and the
  root pids and application names involved. `peak_sessions` is a high-water mark, not a sum: a
  session seen at four samples was not four sessions.
- `lock_tree_prune(older_than interval)`: deletes history older than the given age and returns
  how many. The table only ever grows, one row per blocked session per sample, so this is not
  optional in practice.
- `test/07_history.sql`, 24 assertions: the sample, the rows outliving the incident, the
  segmentation at two thresholds, and pruning at both extremes. It calls `lock_tree_sample()`
  directly rather than scheduling it, so the history logic is tested without depending on
  `pg_cron`. What it does not re-test is whether a scheduler can reach any of it, which
  `test/06_cron.sql` already covers.

### Notes

- `lock_tree_sample()` is `SECURITY DEFINER` so the scheduled job's role needs no `INSERT`
  grant. It takes no arguments and inserts a fixed column list, so there is nothing to steer.
- `sampled_at` is `statement_timestamp()`, which took two attempts to get right and is worth
  recording. `clock_timestamp()` is volatile, so it is evaluated once per **row**: the sessions
  of one sample land microseconds apart, grouping by `sampled_at` yields one group per session
  instead of one per sample, and `peak_sessions` silently becomes 1 in every incident ever
  recorded. `now()` fails the other way, being the transaction timestamp, collapsing everything
  written in one transaction to a single instant. `statement_timestamp()` is stable for the one
  statement that takes the sample and moves between samples.
- Because `lock_tree_sample()` pins `search_path` to `pg_catalog`, a relation name in the history
  can be schema-qualified where the same relation read from your session is not: `regclass`
  renders with or without the schema depending on whether the schema is visible. Pinning is the
  safe choice and the qualification is the better of the two for a record that outlives the
  session which created it, but it is worth knowing before grepping history for a bare table
  name.
- Pruning uses `DELETE`, not `TRUNCATE`, since `TRUNCATE` would take rows you meant to keep.
- `pg_cron` remains a convenience, not a requirement. Any scheduler works, including a host cron
  job calling `psql`, and the extension still needs no `shared_preload_libraries`.

### Fixed

Four bugs, all in the new test file and all found by running it rather than reading it:

- The fixture inserted one row per timestamp, so every sample looked like a single session and
  `peak_sessions` read 1 throughout. Each sample now carries all three depths at one instant,
  which is the point: rows sharing an instant are one observation of one tree.
- Both prune calls ran in one quiet block before the assertion that the rows had survived, so
  "the rows are still there" was checked against an already-emptied table.
- The pruning window was one second, which removed the 13 backdated rows but not the 2 written
  seconds earlier by the live sample. The window has to be older than the newest row, and the
  newest row is always the one just taken, so it is now zero seconds.
- The cleanup terminated pids unconditionally, warning `PID N is not a PostgreSQL backend
  process` twice per run for a session already terminated deliberately. Harmless, and not worth
  leaving: two warnings per run teaches people to ignore warnings, and then a real one goes
  unnoticed.
- `scripts/lint-docs.sh` failed on `lock_tree_history`, because it only looked for `FUNCTION`
  and `VIEW` definitions when checking that a documented object exists. A table is as much a
  documented object as a function. Found by running the linter, which is what it is for.

Verified: 97 tests green on PG 14, 15, 16, 17, 18 and 19beta4 from the registry images; the
0.3 -> 0.4 and 0.2 -> 0.3 -> 0.4 update paths; demo, all seven scenarios and check-install.

## 0.3 (2026-10-04)

The action block, split in two, and two bugs found while checking it. The `lock_tree` view is
untouched: same columns, same values, same semantics, still full and unabbreviated, so anything
selecting from it or grepping for `AccessExclusiveLock` keeps working.
`ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in place; verified from a
clean 0.2 install.

### Fixed

- **A prepared transaction was given advice that could not work.** `lock_tree_roots()` returned
  the generic `pg_cancel_backend(0)` for the pid-0 root, but pid 0 is not a backend:
  `SELECT pg_cancel_backend(0)` returns false and warns `PID 0 is not a PostgreSQL backend
  process`. This was the one case where the queue is genuinely stuck and the operator has no
  other signal, so it is the worst possible place to hand back a no-op. It now says
  `ROLLBACK PREPARED`, and points at `pg_prepared_xacts` for the gid, which this extension
  cannot see. `scenarios/s7_prepared.sql` now exercises the action block, which it previously
  did not, which is why this survived 0.1 and 0.2.
- **`lock_tree_actions()` promised a copy-and-paste command and was not one.** Every line began
  with `--`, so pasting one did nothing at all and still exited 0; extracting just the fragment
  gave `syntax error at or near "pg_terminate_backend"`, since a bare call is not a statement.
  The trailing `;` announced runnability on a line that was inert.
- **`lock_tree_command()` never suggests terminating the session asking the question.** A
  monitoring session can itself be a root blocker; `root_pid <> pg_backend_pid()` now guards it.

### Added

- `lock_tree_command()`: one complete, runnable statement per root blocker, in one column and
  nothing else, so it pastes cleanly, `\copy`s cleanly, or runs all at once with psql's
  `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can
  work: `pg_terminate_backend()` for an idle-in-transaction blocker, since cancelling one could
  not achieve anything, and `pg_cancel_backend()` for anything else, leaving escalation to a
  terminate as the operator's decision. Prepared transactions and your own session produce no
  row, and `lock_tree_roots()` explains both.
- `test/06_cron.sql`: builds a live three-session chain and samples it with a `pg_cron` job,
  asserting the sampled rows outlive the incident. This is the feasibility check for scheduled
  history, not history itself: no retention policy, no threshold alerting. It skips itself
  where `pg_cron` is absent rather than failing.

### Changed

- `lock_tree_actions()` keeps its signature but now returns prose: no runnable statements, no
  semicolons, every line a comment, and a line pointing at `lock_tree_command()`. **This is a
  breaking change for anything parsing its output**, deliberately: the old text claimed to be
  executable and was not.
- `SET lock_tree.actions = off` suppresses `lock_tree_actions()` entirely, for anyone who would
  rather read the roots as the columns `lock_tree_roots()` already gives them. A pure-SQL
  extension can read and test a placeholder GUC without declaring it; `off`, `false`, `no` and
  `0` all switch it off.
- The version guard now says what a backport would cost rather than just refusing. On 13 and
  earlier the extension refuses to install, and the error states that `pg_locks.waitstart` is the
  only blocker and that everything else works on 9.6+. Verified by patching out the three
  `waitstart` references and running the real thing on 13: the tree, roots, depths, paths and
  `blocked_by` were all correct, with only wait age empty.
- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.3.sql`, and its note on why there is no
  `command:` override now covers `pg_cron` as well as `max_prepared_transactions`.
- `scripts/check-install.sh` verifies `lock_tree_command()` and `lock_tree_lines()` exist and
  are callable, and reports whether `pg_cron` is preloaded, so a skip in `test/06_cron.sql` is
  explained rather than mysterious.
- `scripts/lint-docs.sh` (`make lint-docs`, `make check`) and `.forgejo/workflows/lint.yml`:
  checks the documentation's factual claims against the code, since docs rot silently and
  nothing else would notice. Version agreement across `pg_lock_tree.control`, `README.md` and
  `CHANGELOG.md`; every object the docs name is defined in the release SQL; every SQL file is
  installed by the Makefile; every file and test the docs link to exists; each test's `plan()`
  matches its assertions and each `skip()` agrees with its plan; no em-dashes or en-dashes.
  Needs no database, so it runs as its own CI job rather than inside the test matrix.

### Not changed

`pg_lock_tree` still needs no `shared_preload_libraries`. `pg_cron` is a dependency of the test
harness, preloaded in the `pg-test` images so `test/06_cron.sql` has something to schedule. The
other five test files run and pass without it.

## 0.2 (2026-10-04)

Rendering and ergonomics only. The `lock_tree` view's columns, values and semantics are
unchanged and still carry full, unabbreviated names, so anything selecting from the view or
grepping for `AccessExclusiveLock` keeps working. `ALTER EXTENSION pg_lock_tree UPDATE` moves an
existing installation in place; verified from a clean 0.1 install.

### Added

- `lock_tree_text_short(query_width int DEFAULT 100)`: the same tree with abbreviated lock
  modes and session states. Measured at **17% narrower** on a 61-session incident, and the
  default query width is larger precisely because the abbreviations gave the room back.
- `lock_tree_actions()`: one command per root blocker, ordered by how many sessions each
  unblocks, each carrying its blast radius (`blocks N session(s), chain depth D`) on the same
  line. **Deliberately separate from the tree:** with a hundred sessions stuck the tree is
  already a wall of text, and a command on every line would double it. Superseded in **0.3**,
  which found the command was not actually pasteable; see the 0.3 entry.
- `lock_tree_age(interval)`: `4s`, `1m30s`, `2h05m`. Applies to both text forms.
- `lock_tree_mode_short(text)`, `lock_tree_state_short(text)`: `AX`, `idle-in-tx`. Values not
  in the tables pass through unchanged rather than being guessed at.
- `scenarios/`: seven incidents built with `dblink`, each queried both by this extension and
  by the published recursive CTE, with both outputs captured.
- `test/05_formatting.sql`: pins the exact output of the helpers above, since the scenario
  suite derives its width measurements from them.

### Changed

- `lock_tree_text()` output layout. The root line is now `pid  state  age  app  query` rather
  than `pid  [state, xact age]  app (user@db)  query`; waiter lines carry a compact wait age and
  the lock mode without the word "for". Same signature, same defaults, and the per-line
  suggestion moved out to `lock_tree_actions()`.
- `Makefile` now installs update scripts. Listing `pg_lock_tree--0.1--0.2.sql` in `DATA` does
  not work. PGXS copies `DATA` by name and an update path is found by a different convention, so
  so there is an explicit `install-upgrades` target.
- `.forgejo/workflows/test.yml` loads the then-current `pg_lock_tree--0.2.sql`.

### Scenario results

| scenario | waiting | published CTE | pg_lock_tree |
|---|---|---|---|
| 1 nightly batch | 4 | 4 | 4 |
| 2 three chains | 4 | 4 | 4 |
| 3 row locks | 2 | 2 | 2 |
| 4 wide queue | 60 | 60 | 60 |
| 5 advisory locks | 2 | 2 | 2 |
| 6 deadlock | 2 | 2 | 2 |
| 7 prepared transaction | 2 | **0** | 2 |

Coverage ties almost everywhere, and the suite reports that rather than overclaiming. The real
differences are that the published form times out when run verbatim (`s1`, `s4`), returns 40
rows for a 2-session deadlock (`s6`), and cannot see a blocker that has no `pg_locks.pid`
(`s7`).

## 0.1 (2026-10-03)

First release. Pure SQL, PostgreSQL 14+.

### Added

- `lock_tree` view: every session in a lock-wait chain, with `root_pid`, `depth`, `path`,
  `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age` and `query`.
- `lock_tree_roots()`: head-of-line blockers only, ordered by how many sessions each one
  blocks, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`.
- `lock_tree_text(query_width int DEFAULT 60)`: the tree as indented text for psql.
- A session blocked by several blockers is placed on its deepest chain, so the queue order
  reads top to bottom rather than fanning out.
- Prepared transactions appear as a root at pid `0`.
- Relations locked in another database are shown by OID, since names only resolve in the
  current database.
- 31 pgTAP tests across four files, run against PG 14 to 19 by `scripts/matrix.sh` and CI.

### Fixed since the first draft

- **A wait-for cycle no longer empties the tree.** Root finding required a blocker that was
  not itself blocked. In a deadlock every session in the cycle is blocked, so the component
  matched nothing and `lock_tree` returned no rows, precisely when an operator most wants
  output. The walk is now seeded from every blocker and each session in a rootless cycle is
  reported as its own depth-0 root. `test/03_deadlock.sql` builds a real two-session cycle
  and covers this.
- **The documented monitoring grants were incomplete.** `GRANT pg_read_all_stats` alone still
  failed with `permission denied for view lock_tree`; `GRANT SELECT ON lock_tree` is also
  required. `test/02_permissions.sql` pins both halves.

### Notes

- `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it
  only for sessions already waiting on a heavyweight lock. Sample every few seconds at most,
  never in a tight loop.
- Behaviour that needs `max_prepared_transactions > 0` (the prepared-transaction path) is
  covered by `test/04_prepared.sql`; the shared `pg-dev-infra` compose file sets it.