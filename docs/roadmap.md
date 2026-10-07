# roadmap: what is planned, and what was considered and dropped

Organised by what the evidence supports rather than by release, and every item says how we know.
Work that has been done is in the last section, so this one is only ever about what is outstanding.

## Immediate, and in this order

Three items, from the 1.0.1 review. They are proposals, not commitments, and none has been built.
In order, because the first is the only one that is obviously right and the third is the only one
that needs a measurement before anyone can say whether it is worth doing.

**One item, from the 1.0.1 review, and it is the other two done.** The window parameter on
`lock_tree_incidents()` shipped in 1.1.0, and `INCLUDE (query_id)` shipped with it. Both are written
up in the record section at the end. What is left is the one that needs a design decision rather than
a measurement.

**The two statements in `lock_tree_deadlocks()`. RESOLVED in 1.1.4, as a function.**

`lock_tree_deadlocks()` reports *when* a deadlock happened, from the `pg_stat_database.deadlocks`
counter, and names neither participant. Both are recoverable from the history, and this was measured
rather than assumed. On PostgreSQL 16 with `deadlock_timeout` at 15s, a sample taken while a real
two-session cycle existed wrote two rows into `lock_tree_history` at `depth = 0` with `waiting_for`
set and the query text attached, and on the 1,209,620-row benchmark fixture **zero** of the 60,481
`depth = 0` rows have `waiting_for` set. The shape is therefore unique to a deadlock. Re-run and
captured in 1.1.4: `scenarios/s6_deadlock.sql` on PostgreSQL 16 shows both participants at `depth =
0`, `LOCK TABLE s6_x` and `LOCK TABLE s6_y IN ACCESS EXCLUSIVE MODE`, each naming the other.

The decision, which was the part that needed one, was function rather than column. A participant is
only in the history for samples taken inside the `deadlock_timeout` window, so a column on
`lock_tree_history` would be NULL in nearly every row of the table that matters, and an empty column
on the hot table is worse than no column: a reader who queries it sees NULL and concludes no deadlock
happened. That is the misreading this item was worried about, and a column would have caused it.
`lock_tree_deadlock_participants(since)` costs no storage, changes no schema, and puts the caveat in
a `COMMENT` a reader meets at the point of use. The open question about what the column should
contain is answered by there not being a column.

**The 353 ms difference is a fifth scan, and the fifth scan is required.** The per-application variant
has an extra CTE, `qids`, that collects the distinct `query_id`s an application was root for. That step
cost 100 to 160 ms on its own before 1.1.0; `INCLUDE (query_id)` took it to 31.2 ms, so the gap between
the two functions is now 353 ms rather than the 688 ms this paragraph used to quote, and the fifth
scan is still the largest single thing left in the difference. The obvious cheaper shape is to derive it from `rooted`, which is already
filtered to `depth = 0` and grouped by application, and that would remove a scan. It would also be wrong:
`rooted` is at the grain `(sampled_at, application_name)`, and adding `query_id` to that grain takes it
from 23,036 rows to 150,485 on the fixture, because one application can be the root of several queries
at one instant. `rooted` is joined at both ends of every gap, so the wider grain double-counts the gaps
for exactly the applications that were busiest. Measured, not reasoned: that is the row count.

So this is not a defect either, and it is recorded here because the number was quoted at the wrong
function and that is worth correcting in public rather than quietly dropping.

**Open, found while measuring 1.1.2: its cost follows retention even inside its 7-day window.** Asked
about the same seven days, it took 2.3 s on a week of history, 3.6 s on a month, 7.4 s on 90 days and
30.3 s on a year, single runs of [`scripts/bench-history.sh`](../scripts/bench-history.sh) at each
`--days`. `lock_tree_duration()`, beside it in the same runs, stayed between 2.0 and 2.6 s. Not yet
  diagnosed, and the suspect this entry used to name has since been measured and refuted.

  **The suspect it used to name is wrong, on PostgreSQL 18 at least.** The partial index keyed
  on `application_name` before `sampled_at` was the first guess, on the reasoning that a window
  predicate on a non-leading column is a filter rather than a range bound, so `qids` would read
  the whole index and the index grows with retention. Measured: it does not. With in-window rows
  fixed at 2,000 and re-verified before every run, that index scan read 185 buffers and then 165
  while 900,000 out-of-window `depth = 0` rows were added and the index grew to 38 MB. The
  `sampled_at` predicate is a usable bound, not a filter, so `qids` is window-bounded and is not
  the cause.

  Two caveats on that refutation. It was measured on 18 only, and B-tree skip scan, which is what
  makes a non-leading column usable here, arrived in that release. On 14 to 17 the original
  reasoning may still hold and is worth one run rather than an assumption. And on 18 it rules out
  this suspect, not the symptom: something still makes the cost follow retention.

And one more suspect was raised, wrongly refuted, and turned out to be the answer. Kept in full
  because the wrong turn is more instructive than the right one, and because a confident false
  negative is worse than an open question: it stops people looking.

  `lock_tree_duration_by_application()` bounds only the root side of its root-to-waiter join.
  PostgreSQL does not carry `r.sampled_at >= now - since` across the equality
  `w.sampled_at = r.sampled_at`, so whether the waiter side stayed inside the window depended on
  which join the planner chose. A nested loop probes it, about 19 rows per root. A merge join, a
  hash join or a sequential scan reads every `depth > 0` row in the table, so the cost follows
  retention rather than the window asked about. `lock_tree_duration()` has the identical join and
  was handed a nested loop, which is why the two disagreed despite identical SQL.

  Fixed in 1.1.5 by stating the bound on the waiter side. It cannot change the result, since the
  join equates `sampled_at` and the root side is bounded. Default 7-day window, old and new
  alternating on one fixture, best of three:

  | fixture | function | 1.1.4 | 1.1.5 | waiter rows read |
  |---|---|---|---|---|
  | PG18, 90 days | `duration()` | 2480 ms | 2511 ms | 19 either way |
  | PG18, 90 days | `by_application()` | 6989 ms | 2155 ms | 14,774,419 to 1,143,439 |
  | PG14, 30 days | `duration()` | 2265 ms | 2335 ms | 19 either way |
  | PG14, 30 days | `by_application()` | 3417 ms | 2397 ms | 4,924,819 to 1,148,854 |

  `duration()` is bounded too although its plan does not change on a healthy fixture, because that
  is not guaranteed: on PG14 with unusable statistics it fell back to a sequential scan over every
  waiter row, 7,917 ms against 2,806 ms with the bound.

  **The wrong turn.** A draft of 1.1.4 built this change, measured 4,924,819 waiter rows against
  1,149,405 and 3548 ms against 2210 ms, then could not reproduce any of it and discarded the
  clause. It rebuilt the comparison from the installed source, ran an explicit `ANALYZE`, and
  deleted every row of `pg_statistic` so the planner had no statistics at all. Every time, 1.1.4
  read 1,149,405 rows, bounded, and looked correct.

  The error was treating a plan difference as a property of the SQL. It was a property of one
  planner, on one version, with one fixture. On PG18 with a 90-day fixture `by_application()` is
  given a nested loop and is fast; on PG14 with a 30-day one it is given an index scan with only a
  filter and reads everything ever retained. Same SQL, same query, and the symptom appears and
  disappears with version, statistics and size. Testing a plan-dependent property on one
  configuration proves nothing, and the note to write is "not reproducible **here**, reason not yet
  understood", not "does not reproduce".

  **A second trap, in the comparison rather than the SQL.** Run the two bodies in separate
  statements and they can differ without either being wrong. `statement_timestamp()` moves and the
  sampler runs on a grid, so the window boundary shifts between calls, and these functions do not
  agree with **themselves** across two consecutive calls: two runs of one query gave different
  checksums. Each old and new pair must run inside a single statement, or the comparison measures
  the clock.

  **A third, in the tooling.** `scripts/bench-history.sh` ran `VACUUM (ANALYZE)` with its output
  discarded and never checked the result. On PG14 in Docker the parallel index phase needs more than
  the default 64 MB `/dev/shm`, so the vacuum failed and the script printed timings for an
  unvacuumed, unanalysed table: 9.0 s where 2.3 s was the truth. Now `PARALLEL 0`, and, the part
  that matters, the script refuses to report any timing when the vacuum fails.

  **What this does to the visibility-map hypothesis.** It was a reasonable guess at a symptom with
  two causes. The waiter-side scan is now explained and fixed, and it accounted for the asymmetry
  between the two functions on its own. The visibility-map effect may still be real at a year and
  the 365-day reading is still worth doing, but it is no longer the first place to look, and
  `duration()` being flat across retention is now explained by its plan rather than left dangling.
  So the suspect list is shorter, not empty. The plan at 365 days is still the next thing to
  read, now looking for a node whose buffers or heap fetches grow with total table size rather
  than with the rows in the window. The leading remaining candidate is the visibility map: at 63
  million rows and 14 GB with constant appends, autovacuum falls behind, pages stop being marked
  all-visible, and index-only scans degrade into random heap fetches. `duration()` staying flat
  beside it is consistent with that, since its worst node is not an index-only scan. That is a
  hypothesis, not a finding.

## The whole-window duration read, measured rather than assumed

This was the first item on the list for several releases, on the reasoning that the four CTEs each
re-read the history and merging them into one pass should help. It does not. Three versions were built
and timed against the same fixture, alternating with the shipped function so both saw the same cache.
Every figure is a mean of four runs of the `root_wait` join, which is 43% of the function.

| Version | Mean |
|---|---|
| Shipped: the root rows probe the same sample's waiter rows | **643.9 ms** |
| The waiters aggregated once by (sample, root, object), then joined | 643.0 ms |
| One materialised CTE, read once, all four CTEs derived from it | **worse than the whole function** |

The third is the interesting failure, and it is the one the reasoning predicted would work. A CTE has
no index, so the self-join degenerates from an index probe per root row into a scan of the materialised
set, and the function went from 1,460 ms to 2,900 ms. Reading the table once is not the same as reading
it cheaply, and merging passes over an indexed table loses more than it saves.

A **covering index** on `(sampled_at) INCLUDE (depth, query_id, root_pid, root_object, wait_age, pid)`
was built and measured: 79 MB, 42% of the heap it indexes, for no measurable gain. The planner used it
for one side of the join and the time did not move, because the cost is not the heap access.

`work_mem` buys about 10%: 1,360 ms at 4 MB, 1,220 ms at 256 MB. Not a code change, not worth
documenting as a requirement.

So the remaining cost is the 187 MB heap scan and the aggregate over 1.15 million joined rows, and neither
is removable by restructuring. It stays the slowest read in the extension, and the thing that would
change it is not a better query.

## `lock_tree_duration_by_application()`, and a number that belonged to something else

This started as a suggestion to review `lock_tree_statements()` for being slow, on the strength of a
3026 ms figure in a benchmark table. **That figure is not `lock_tree_statements()`.** It belongs to
`lock_tree_duration_by_application()`, and `lock_tree_statements()` was not in the benchmark at all: it
appears zero times in `scripts/bench-history.sh`. Measured against the same fixture:

| Function | Time | Reads |
|---|---|---|
| `lock_tree_statements()` | **15.8 ms** | the live tree, and `pg_stat_statements` |
| `lock_tree_roots()` | 2.6 ms | the live tree |
| `lock_tree_text()` | 11.4 ms | the live tree |
| `lock_tree_duration()` | 1810.0 ms | the history |
| `lock_tree_duration_by_application()` | 2163.5 ms | the history |

These are the figures [`scripts/bench-history.sh`](../scripts/bench-history.sh) prints on PostgreSQL 18
against the standard fixture: seven days, every 10 seconds, 20 blocked sessions, 1,209,620 rows. The
two history rows changed in 1.1.0, and why is the subject of the next section: until then the script
timed every read function as `SELECT count(*)`, which lets the planner drop output columns nobody
selects, so it timed `lock_tree_duration_by_application()` without the `qids` CTE at all.

Seventeen milliseconds against seven days of history, because it reads the tree as it is now and joi
`pg_stat_statements`. It was never a candidate for review and the suggestion was wrong.

The benchmark now times the live-tree reads as their own group, labelled as such, so that a reader does
not have to know which function touches the history to know which will be slow. That is the whole fix,
and the omission is what let the wrong number be quoted.

**The 353 ms difference is a fifth scan, and the fifth scan is required.** The per-application variant
has an extra CTE, `qids`, that collects the distinct `query_id`s an application was root for. That step
cost 100 to 160 ms on its own before 1.1.0; `INCLUDE (query_id)` took it to 31.2 ms, so the gap between
the two functions is now 353 ms rather than the 688 ms this paragraph used to quote, and the fifth
scan is still the largest single thing left in the difference. The obvious cheaper shape is to derive it from `rooted`, which is already
filtered to `depth = 0` and grouped by application, and that would remove a scan. It would also be wrong:
`rooted` is at the grain `(sampled_at, application_name)`, and adding `query_id` to that grain takes it
from 23,036 rows to 150,485 on the fixture, because one application can be the root of several queries
at one instant. `rooted` is joined at both ends of every gap, so the wider grain double-counts the gaps
for exactly the applications that were busiest. Measured, not reasoned: that is the row count.

So this is not a defect either, and it is recorded here because the number was quoted at the wrong
function and that is worth correcting in public rather than quietly dropping.

**Open, found while measuring 1.1.2: its cost follows retention even inside its 7-day window.** Asked
about the same seven days, it took 2.3 s on a week of history, 3.6 s on a month, 7.4 s on 90 days and
30.3 s on a year, single runs of [`scripts/bench-history.sh`](../scripts/bench-history.sh) at each
`--days`. `lock_tree_duration()`, beside it in the same runs, stayed between 2.0 and 2.6 s. Not yet
  diagnosed, and the suspect this entry used to name has since been measured and refuted.

  **The suspect it used to name is wrong, on PostgreSQL 18 at least.** The partial index keyed
  on `application_name` before `sampled_at` was the first guess, on the reasoning that a window
  predicate on a non-leading column is a filter rather than a range bound, so `qids` would read
  the whole index and the index grows with retention. Measured: it does not. With in-window rows
  fixed at 2,000 and re-verified before every run, that index scan read 185 buffers and then 165
  while 900,000 out-of-window `depth = 0` rows were added and the index grew to 38 MB. The
  `sampled_at` predicate is a usable bound, not a filter, so `qids` is window-bounded and is not
  the cause.

  Two caveats on that refutation. It was measured on 18 only, and B-tree skip scan, which is what
  makes a non-leading column usable here, arrived in that release. On 14 to 17 the original
  reasoning may still hold and is worth one run rather than an assumption. And on 18 it rules out
  this suspect, not the symptom: something still makes the cost follow retention.

  So the suspect list is shorter, not empty. The plan at 365 days is still the next thing to
  read, now looking for a node whose buffers or heap fetches grow with total table size rather
  than with the rows in the window. The leading remaining candidate is the visibility map: at 63
  million rows and 14 GB with constant appends, autovacuum falls behind, pages stop being marked
  all-visible, and index-only scans degrade into random heap fetches. `duration()` staying flat
  beside it is consistent with that, since its worst node is not an index-only scan. That is a
  hypothesis, not a finding.

## The eight checks: running, via a pre-baked runner image

`scripts/check-*.sh` (six of them), `scenarios/run.sh` and `demo.sql` all gate on a row in
`pg_extension`, which exists only if the extension was installed with `CREATE EXTENSION`. The pgTAP
matrix deliberately loads the release SQL straight into `public`, because the server is a separate
service container, so for most of this project's life these eight could not run in CI at all.

**The image was never the obstacle.** The recorded assumption was that the service container held
an older baked copy of the extension, so the fix was thought to need rebuilt images and a
`write:package` decision. Checked: `apjapj/pg-test:18` contains **zero** `pg_lock_tree` files. Not
a stale version, none at all. There was no version skew to correct.

**What did not work, and why it is worth keeping.** A job that started its own Postgres from the
same image with the checkout mounted, copied the extension files in, ran `CREATE EXTENSION` and ran
all eight, worked perfectly by hand against the real image. Pushed, it **failed in 9 seconds** while
every matrix job passed. A job container has no `docker` binary: `node:20-bookworm`, which is what
jobs run in, has neither docker nor psql. That the error is literally `command not found` is an
inference, not an observation, since `/actions/jobs/{id}/logs` 404s at `read:repository`; the
9-second duration and the absent binary are consistent with it and with nothing else.

**What works.** `pg-dev-infra` builds a dedicated job image, `apjapj/pg-runner:18-20261007`, from
`node:20-bookworm` with PostgreSQL 18, `pg_cron`, `pg_stat_statements`, pgTAP, the TAP parser,
`make` and `gcc` baked in, plus a `pg-start` helper that brings up a preconfigured cluster on
localhost. The runner's `babar-pg` label names it; `docker` is untouched, so `book-platform`,
`lint.yml` and `secrets.yml` are unaffected. The job then needs no apt, no docker and no socket:

```bash
pg-start
make install
psql -c "CREATE EXTENSION pg_lock_tree"
```

This is the option I called "install PostgreSQL in the job", with the install moved to image build
time and owned by `pg-dev-infra`, which is where it belongs. I should have reached for the image
rather than the job.

Verified end to end: all eight pass locally in the image, and in CI the `install-path checks` job
runs them on PostgreSQL 18 in about 1m50s. One version, not the matrix, because these are about
the install path rather than a version's behaviour. The checks are listed by name rather than
globbed, so adding a file cannot silently change what CI runs.

**Four bugs found along the way**, all of the kind a green run hides rather than shows. The
container was started with no published port, so `PGPORT` was empty and every check dialled a port
where nothing listened. The files were copied but `CREATE EXTENSION` never ran, so four of the eight
failed with "not installed in this database": copying files is not installing the extension. The
image tag carried no registry host, so the push went to `docker.io` and failed with
`insufficient_scope`. And `pg-start` exited non-zero on a second call, so a reused container would
fail on its first line.


## Considered and not planned

- **Cross-database.** The extension lives in each database, as all extensions do, so a queue on
  `reporting` is invisible from `production`. Deliberately not here: this is a per-database
  diagnostic, and a fan-out sampler is a separate tool wearing this one's name.
- **`lock_tree_history` partitioned by month**, so `lock_tree_prune()` becomes a DETACH rather than
  a DELETE. The shape suits partitioning and the retention argument is real, and it is still not
  worth doing, because the access side gets **worse**, not better. Re-measured in 1.1.0 against a
  range-partitioned clone of the standard fixture, daily partitions plus a DEFAULT, carrying the same
  four indexes, with the function bodies copied from the shipped ones by substituting the table name
  and nothing else. Cold `shared_buffers` for every measurement, because a warm-cache pass made
  partitioning look three times worse than it is.

  | window | `duration()` flat | partitioned | `by_application()` flat | partitioned |
  |---|---|---|---|---|
  | 7 days | 1606 ms | 2224 ms (**+38%**) | 2249 ms | 3324 ms (**+48%**) |
  | 1 day | 257 ms | 233 ms (−9%) | 308 ms | 933 ms (**+203%**) |
  | 6 hours | 61 ms | 67 ms (+10%) | 69 ms | 77 ms (+11%) |

  Partition pruning does work: at a one-day window the plan touches two daily partitions instead of
  eight. Pruning is not the problem. The problem is that the planner does not choose a partition-wise
  join for the `root_wait` self-join, and without one the inner side of a nested loop loses its
  pruning qual and becomes an eight-way `Append` executed once per outer row:

  ```
  ->  Append (actual rows=19.00 loops=8610)
        ->  Index Scan using lock_tree_history_p_20260928_sampled_at_...
        ->  Index Scan using lock_tree_history_p_20260929_sampled_at_...
        ... all eight partitions
  ```

  8,610 loops times eight partitions is 68,880 partition index scans, reading 1,149,139 rows to answer
  a 172,320-row question. That single node is the 203%. Two smaller costs ride along: `Merge Append`
  replaces one ordered scan and adds an 886 ms sort above it, and the DEFAULT partition is
  sequentially scanned on every query even when it holds nothing.

  Two structural reasons remain, independent of performance. PostgreSQL has no `ALTER TABLE ... SET
  PARTITIONED BY`, so this cannot be adopted in place. And a DEFAULT partition is **not optional**:
  the test suite inserts history rows up to nine days old, so without one those inserts fail outright,
  and with one, anything older than the earliest partition accumulates where it can never be pruned.

  What partitioning *would* buy is retention, not access: `DROP TABLE` on a partition is instant
  where `lock_tree_prune_batched()` deletes in committed batches and leaves dead tuples. If pruning
  is the operational pain, the answer is a documented pruning cadence, not a schema change. The
  measurements behind the original decision are in the 0.11 changelog, and
  `lock_tree_history_size()` and `lock_tree_prune_batched()` are what shipped instead.
- **Registering the tables for `pg_dump`.** Decided against, with reasons per table, and the decision
  is now pinned by a test and written up in [`INSTALL.md`](../INSTALL.md#backups-and-restores). The short
  version: `lock_tree_history` grows without bound and describes pids and timestamps that mean
  nothing on the server a restore lands on; `lock_tree_alert` is hysteresis for roots that exist only
  on the source; `lock_tree_deadlock` is a counter baseline whose target starts again from zero.
- **Column order on the tables.** Cannot be made consistent across install paths, and the evidence is
  in `scripts/check-upgrade.sh`: `ALTER TABLE ADD COLUMN` appends, so a database older than 0.8 keeps
  `root_object` at the end of the row and displaces what followed it. Rebuilding `lock_tree_history`
  to reorder it would need twice the disk and hold `ACCESS EXCLUSIVE` for the length of the copy.
  Instead the difference is a named, checked exception, and the stability statement says `SELECT *` on
  the tables is outside the contract.

## Open questions, not commitments

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

## Done, and where to read about it

Recorded here so the section is a record rather than a wish list. Each is one line because the
changelog has the detail and a test has the proof.

- **`lock_tree_incidents()` without the disk sort** (1.1.2): the `DISTINCT` taken before each array
  rather than inside `array_agg`, so the array subplans no longer spill. Identical output; 15% faster on
  a week of history and 31% on a year, measured at each retention in
  [docs/history.md](history.md#incidents-in-112).
- **A window on `lock_tree_incidents()`** (1.1.0), the last history read function whose cost followed
  retention rather than the question. Measured at 2.00 us per row as a caller uses it, which is 2.5
  seconds for a week of the standard fixture and 10.9 seconds for a month at its sampling rate, with
  no way to ask about less; `since` takes a week to 315 ms. The default is `NULL` rather than seven
  days precisely so that no existing call changes.
- **The per-row figures in the retention table**, re-measured after the 1.1.0 release because
  investigating that window parameter turned up an arithmetic error in the projection. `incidents()`
  was costed at three times its measured per-row rate, so the 90-day figure read 91 s against 32.7 s
  measured and the yearly figure read 364 s against 132.5 s. `duration()` was understated by about a
  quarter the other way. The table and the method are now in
  [docs/history.md](history.md#holding-more-than-a-few-weeks), which says what was measured rather
  than leaving the arithmetic to be trusted.
- **`INCLUDE (query_id)` on `lock_tree_history_application_idx`** (1.1.0), which turns the `qids` step
  from a bitmap heap scan fetching 24,133 pages into an Index Only Scan with `Heap Fetches: 0` and
  300, taking that step from 117.0 to 31.2 ms for 528 kB on a 1.9 MB index. A four percent win on a
  two-second function, and recorded as such rather than as a fix.
- **A benchmark that measured less work than it claimed** (1.1.0). [`scripts/bench-history.sh`](../scripts/bench-history.sh) timed every read
  function as `SELECT count(*)`, which lets the planner drop any output column nobody looks at. For
  `lock_tree_duration_by_application()` that dropped the whole `qids` CTE: 2048 ms against 2249 ms for
  `SELECT *`, a published figure a tenth light for `lock_tree_incidents()`. The script now times
  `SELECT *`, vacuums the fixture first, and asserts in its own output that the aggregation it is
  timing is still in the plan, with the half of the check that shows `count(*)` still drops it.
- **Generated examples** (`scripts/capture.sh` and `scripts/lint-docs.sh`), for the blocks that were
  hand-transcribed measurements: the coverage table in scenarios/README.md, the lock tree in the README,
  the actions block and the command beside it, and the order the demo prints. Each is captured with
  pids, waits and timestamps masked, and compared on every run. The examples that remain written are
  marked as written, and the demo now builds the incident the README illustrates so that the last of
  the README's two could become a capture too.
- **The whole-window `lock_tree_duration()` read**, investigated and then left alone. Three candidate
  implementations were built and measured: one was twice as slow, one made no measurable difference, and
  a covering index cost 79 MB for nothing. The section above has the numbers and why the reasoning
  behind the item was wrong.
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
- **The non-public schema install** (`test/22_schema_install.sql` and `make check-schema`), for the
  one situation where an unqualified call to a sibling fails: both `search_path`-pinned functions.
  The end-to-end half needs a second database, so it is a make target rather than part of the suite.
- **The README's nine factual errors, and the split** into a short entry point plus `docs/` and
  `CONTRIBUTING.md`, with a link and anchor check so the moved sections cannot quietly break it again.
