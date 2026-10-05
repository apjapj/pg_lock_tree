# roadmap: what is planned, and what was considered and dropped

Organised by what the evidence supports rather than by release, and every item says how we know.
Work that has been done is in the last section, so this one is only ever about what is outstanding.

## Immediate, and in this order

Three items, from the 1.0.1 review. They are proposals, not commitments, and none has been built.
In order, because the first is the only one that is obviously right and the third is the only one
that needs a measurement before anyone can say whether it is worth doing.

**A window parameter on `lock_tree_incidents()`.** It takes `max_gap` and nothing else:

    lock_tree_incidents(max_gap interval DEFAULT '00:05:00')

Its two neighbours both take one, and both default to seven days:

    lock_tree_deadlocks(since interval DEFAULT '7 days')
    lock_tree_sampling_advice(since interval DEFAULT '7 days')

So the history functions that answer "what happened" can be bounded, and the one that segments the
history into incidents cannot. On a database whose history has been kept for a year, that is the
whole table scanned to answer a question about last Tuesday. Adding `since interval DEFAULT '7 days'`
as a second parameter is additive, so every existing call site keeps working. It is not free: the
segmenting reads `sampled_at` in order and the parameter has to participate in the gap test rather
than sit in a `WHERE` that could change which rows are adjacent to which.

**The two statements in `lock_tree_deadlocks()`.** `lock_tree_deadlocks()` reports *when* a deadlock
happened, from the `pg_stat_database.deadlocks` counter, and names neither participant. Both are
recoverable from the history, and this was measured rather than assumed. On PostgreSQL 16 with
`deadlock_timeout` at 15s, a sample taken while a real two-session cycle existed wrote two rows into
`lock_tree_history` at `depth = 0` with `waiting_for` set and the query text attached, and on the
1,209,620-row benchmark fixture **zero** of the 60,481 `depth = 0` rows have `waiting_for` set. The
shape is therefore unique to a deadlock, and a window join on `sampled_at` is what would surface it.

The catch is stated in `docs/after-the-incident.md` and belongs here too: it works only if a sample
happened to land while the cycle existed, which needs `deadlock_timeout` longer than the sampling
interval. At the default one second it almost never will. A column that is usually empty is still
worth having, but it must say so, or it will be read as a promise.

**Measuring `INCLUDE (query_id)` on the application index.** The index is:

    CREATE INDEX lock_tree_history_application_idx ON lock_tree_history
    USING btree (application_name, sampled_at) WHERE depth = 0

`lock_tree_statements()` reads that index and then visits the heap for `query_id`, `query` and the
wait columns. Adding `INCLUDE (query_id)` would put the one column the grouping needs into the leaf,
without making the index bigger by much, because it is dropped from the leaf on a non-leaf split.
**This has not been measured.** The benchmark figure for `lock_tree_statements()` is 17.9 ms on the
standard fixture, which is not slow, so the size of the win is unknown and the size of the cost is
also unknown. Measure both before writing anything: the added index size, and the same function timed
with and without it. A covering index for the `lock_tree_duration()` join was measured in the past and
came to 79 MB for no gain, which is the reason to expect this to go badly and also the reason to
measure rather than assume.

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
| `lock_tree_statements()` | **17.9 ms** | the live tree, and `pg_stat_statements` |
| `lock_tree_roots()` | 2.4 ms | the live tree |
| `lock_tree_text()` | 12.8 ms | the live tree |
| `lock_tree_duration()` | 1941.6 ms | the history |
| `lock_tree_duration_by_application()` | 2629.6 ms | the history |

Seventeen milliseconds against seven days of history, because it reads the tree as it is now and joins
`pg_stat_statements`. It was never a candidate for review and the suggestion was wrong.

The benchmark now times the live-tree reads as their own group, labelled as such, so that a reader does
not have to know which function touches the history to know which will be slow. That is the whole fix,
and the omission is what let the wrong number be quoted.

**The 688 ms difference is a fifth scan, and the fifth scan is required.** The per-application variant
has an extra CTE, `qids`, that collects the distinct `query_id`s an application was root for, and it
costs 100 to 160 ms on its own. The obvious cheaper shape is to derive it from `rooted`, which is already
filtered to `depth = 0` and grouped by application, and that would remove a scan. It would also be wrong:
`rooted` is at the grain `(sampled_at, application_name)`, and adding `query_id` to that grain takes it
from 23,036 rows to 150,485 on the fixture, because one application can be the root of several queries
at one instant. `rooted` is joined at both ends of every gap, so the wider grain double-counts the gaps
for exactly the applications that were busiest. Measured, not reasoned: that is the row count.

So this is not a defect either, and it is recorded here because the number was quoted at the wrong
function and that is worth correcting in public rather than quietly dropping.

## Considered and not planned

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
