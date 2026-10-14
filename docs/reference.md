# reference: one object, one answer

**For: someone who knows which function they want and wants its columns.** Every object the extension
creates, the stability statement, and the NOTIFY payload keys.


## Objects

> **Monitoring roles.** Seven of the functions below read `lock_tree_history` and are
> `SECURITY INVOKER`, so they need `GRANT SELECT ON lock_tree_history` on top of the two grants in
> [INSTALL.md](../INSTALL.md#grants). `lock_tree_replay_samples` is a view and works without it, because
> a view runs with the definer's rights. That inconsistency is stated rather than fixed, and the
> reasons are in INSTALL.md.

| Object | Use |
|---|---|
| `lock_tree` (view) | Every session in a blocking chain: `root_pid`, `root_object`, `depth` (0 is the root), `path`, `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age`, `query`, `query_id`, plus user, database, application and client. Ordered root first. `root_object` is what a prepared-transaction root holds, since `root_pid` is 0 for all of them. `query_id` was added in 0.16 so the live tree can be joined to `lock_tree_history` on it; it is `NULL` on waiters, because a blocked query has none until it completes. |
| `lock_tree_roots()` | One row per root blocker, most sessions blocked first, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`. |
| `lock_tree_text(query_width int DEFAULT 60)` | The tree as indented text, for reading in psql during an incident. Full unabbreviated names. |
| `lock_tree_text_short(query_width int DEFAULT 100)` | The same tree with abbreviated modes and states, for when the queue is wide. Measured 17% narrower on a 61-session incident. |
| `lock_tree_lines(query_width int, short boolean)` | The renderer behind `lock_tree_text()` and `lock_tree_text_short()`. Exposed so the width comparison in `scenarios/s4` can attribute the saving to each abbreviation separately, which is the only way to tell a shorter mode from a shorter column |
| `lock_tree_actions()` | A written description of each root blocker and its blast radius, ordered by how many sessions each unblocks. Prose only, no runnable statements. `SET lock_tree.actions = off` suppresses it. |
| `lock_tree_command()` | One complete, runnable statement per root blocker, for pasting or for `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can work. |
| `lock_tree_history` (table) | Sampled trees, one row per session per sample. Empty until you schedule a sample. `query_id` on root rows only, since a blocked query has none. |
| `lock_tree_deadlock` (table) | `pg_stat_database.deadlocks` sampled on its own beat, whether or not anything is blocked. Naming no participants: the two statements are in the server log. Pruned by `lock_tree_prune()`. |
| `lock_tree_sample()` | Take one snapshot into `lock_tree_history`. Returns rows written, 0 when nothing is blocked. Nothing calls it for you. |
| `lock_tree_incidents(max_gap interval DEFAULT '5 minutes', since interval DEFAULT NULL)` | The history grouped into incidents: when each ran, peak sessions blocked, deepest chain, longest wait, and the root pids and application names involved. `since` bounds the window and defaults to `NULL`, meaning the whole retained history; on a long retention, pass it. |
| `lock_tree_prune(older_than interval)` | Delete history older than the given age, return how many **history** rows went, which is what it has always returned. The table only grows otherwise. |
| `lock_tree_history_size()` | What the history costs now and what it will cost at the rate it is already being written: rows, samples, total bytes, the observed sample interval, bytes per day, and days until it reaches a gigabyte. `archive_bytes`, added in 1.1.7, is the size of `lock_tree_history_archive` and is **not** folded into `total_bytes`; add the two for a whole-database figure. **This is the one function whose cost follows retention rather than the question**: 6.7 s on a year of history (63,072,020 rows, 3,153,601 samples, PostgreSQL 18), of which about 5.0 s is `count(DISTINCT sampled_at)`. So it gets slower for exactly the installations that need it most, and an operator sizing a disk should expect to wait. Two measured points, and no more than two: 181 ms on the 1,209,620-row benchmark fixture and 6.7 s on 63,072,020 rows, which is 52 times the rows for 37 times the time. Both fixtures hold 20 sessions per sample, so the ratio of sample instants to rows is the same in each and that does not explain the gap; fixed per-call cost, caching and plan differences are all plausible and none has been isolated. Do not read a shape into it. |
| `lock_tree_prune_batched(older_than interval, batch_size integer)` | A **procedure**, not a function. The same prune in committed batches, so no single lock is held for the whole of it. Cannot be called inside a transaction block, and checks for one before deleting anything. |
| `lock_tree_history_archive` (table) | The cold tier: history older than what you keep hot, moved here by `lock_tree_archive()`. Same columns as `lock_tree_history`, indexed by BRIN on `sampled_at` and by nothing else, which is what keeps a year of it affordable. **Two shipped functions read it**: `lock_tree_history_size()` has reported its `archive_bytes` since 1.1.7, and `lock_tree_archive_find()` searches it since 1.1.8. What no shipped function does is *span* it, so a `since` window on any other read function still stops at the hot boundary rather than erroring. New in 1.1.6 |
| `lock_tree_archive_find(since interval, until interval DEFAULT NULL, waiting_like text DEFAULT NULL, application text DEFAULT NULL, min_wait interval DEFAULT NULL, limit_rows integer DEFAULT 200)` | Search `lock_tree_history_archive` and **only** the archive. One row per sample instant that matched, newest first, capped at `limit_rows` so a year of history returns something readable. `waiting_like` is a case-insensitive **substring** of the lock tag, with `%` and `_` matched literally rather than as wildcards; `application` is an exact `application_name`; `min_wait` drops shorter waits. **`since` is required** because a NULL cannot become an index bound, and **it is not a performance bound**: a window wider than the archive is accepted and reads all of it. Cost follows the rows the window contains. On 1,209,600 archived rows in `sampled_at` order (correlation 1.0), PostgreSQL 18, the planner's bitmap scan on the BRIN beat a forced sequential scan at every coverage measured, 71 ms against 296 ms at 14% of the rows and 495 ms against 531 ms at 86%; with no bound there is nothing for the index to prune and a sequential scan reads all of it in about 370 ms. The index is not a penalty at full coverage, which 1.1.9 said it was: that compared a single-backend bitmap scan with a two-worker parallel scan. Most of the function's cost is its per-sample aggregation rather than the scan, 467 ms at 14% of those rows and 2.63 s for all of them, so a narrower window saves time in proportion to what it excludes. The `samples` column present in 1.1.8 was removed: it was the constant 1. A window reaching into the last few days returns only what is already archived, so use `lock_tree_incidents()` or `lock_tree_replay()` for the hot end. `waiting_for` is NULL on root rows, so a search finds the waiters, not the blockers. New in 1.1.8, corrected in 1.1.9 and 1.1.10 |
| `lock_tree_archive_since_guard(interval)` | The argument check `lock_tree_archive_find()` uses to refuse a NULL window. Not useful on its own; it exists because a `RETURNS TABLE` function in SQL cannot raise, and a guard joined into the query sits below the function's own `LIMIT` and is never reached. New in 1.1.8 |
| `lock_tree_archive(older_than interval, batch_size integer DEFAULT 10000)` | Move history older than an age into `lock_tree_history_archive`, in committed batches, so no single transaction holds everything and no single statement doubles your peak disk. Re-applies `lock_tree_redact()` to the query text as rows cross, so the archive cannot preserve a laxer redaction policy than the one you run now. A **procedure**, for the same reason `lock_tree_prune_batched()` is one. **It does not free disk**: the hot table stays at its file's high-water mark, and a table pruned on a fixed cycle never exceeds that in the first place. New in 1.1.6 |
| `lock_tree_wide()` | One row per root instead of one per session: how many sessions each blocks, the deepest chain under it, the longest wait, and what they are waiting for. Use when the tree is too wide to read. |
| `lock_tree_summary()` | One row for the whole queue: sessions blocked, roots, deepest chain, longest wait, oldest root transaction. Zeros on a quiet database, not no rows, so it drops straight into a dashboard. |
| `lock_tree_statements()` | Per root, what `pg_stat_statements` already knows about the query holding the lock: normalised text, calls, mean and total time. Groups incidents by query rather than by pid. Optional; see below. |
| `lock_tree_notify(channel, min_blocked, min_depth, min_wait)` | Raise a `NOTIFY` when a chain is bad enough, and remember it so the same incident notifies once rather than on every sample. Escalates on more sessions, more depth, or a longest wait that has **doubled**. Returns how many it raised, so zero is the normal result. |
| `lock_tree_notify_resolved(channel, min_blocked, min_depth, min_wait)` | Raise one `NOTIFY` with `event: "cleared"` per root that **had alerted** and has now left the tree, then forget the stored state so the next incident alerts from the start. Same thresholds as `lock_tree_notify()`, and it reads and writes the same rows. Optional; see below. |
| `lock_tree_policy_key(min_blocked, min_depth, min_wait)` | The alert policy key: the thresholds as one string, `off` for one switched off. `lock_tree_notify()` writes `lock_tree_alert` rows under it and `lock_tree_notify_resolved()` reads them back, so both call this rather than each building it. A helper, not part of the stable surface. New in 1.1.16 |
| `lock_tree_deadlocks(since interval DEFAULT '7 days')` | When `pg_stat_database.deadlocks` moved: the cumulative counter, how far it moved, whether it was reset, and the window total. Names no participants; the timestamp is how you find the log entry, and the history may hold them (see [What it cannot tell you](after-the-incident.md#what-it-cannot-tell-you)). |
| `lock_tree_deadlock_participants(since interval DEFAULT '7 days')` | Both participants of a deadlock, one row per participant per sample, with `partner_pids` naming the other side. **Empty is normal** and does not mean no deadlock happened: it has rows only for samples taken while the cycle still existed, which is the `deadlock_timeout` window. Roughly one deadlock in ten at the defaults. Use `lock_tree_deadlocks()` to find the rest. New in 1.1.4 |
| `lock_tree_alert` (table) | What `lock_tree_notify()` has already alerted on, per channel, per threshold set, per root. Holds three high-water marks, recorded at the last notification rather than at the last sample. Maintained by the function; you should never need to look at it. |
| `lock_tree_prune_alerts(older_than interval)` | Forget alert state orphaned by a restart or a retired channel. |
| `lock_tree_history_statements(since interval DEFAULT '7 days')` | Per-query blocking from the sampled history as **session-samples**: one unit per blocked session per sample. Answers "which statement blocks the most sessions", which is the right question when the shape of the damage matters more than its cost. Does not move with the sample rate in units of time, because it is not a time; see the next row. |
| `lock_tree_duration(since interval DEFAULT '7 days')` | Per-query blocking **TIME** from the sampled history, worst first: for each root query id, the elapsed time during which it was holding the queue up, with the peak and total sessions it blocked and the longest single wait it caused. Does not move with the sample rate, which is the whole difference. A gap counts only where the query was the root at both ends, and the interval after the last sample is never counted, so it is a lower bound rather than an estimate. |
| `lock_tree_duration_by_application(since interval DEFAULT '7 days')` | The same **TIME**, keyed on `application_name` instead of the statement, with the statements it was root for. Not the same figure and not a re-grouping: see [Which application is costing the most](incident.md#which-application-is-costing-the-most). An empty `application_name` is reported as its own row, because a blocker that never set one is a finding. |
| `lock_tree_replay_samples` (view) | One row per sample in the history: when it was taken, how many roots were blocking, how many sessions behind them, how deep, the longest wait, and the applications and query ids at the head. The history holds one row per *session*, so this is how you find out which moments you can ask for. |
| `lock_tree_replay(as_of timestamptz DEFAULT NULL)` | The lock tree as it was at a past sample, from the history. Takes a target and uses the sample **nearest** it, reporting which one in `sampled_at`. `NULL` means the most recent. |
| `lock_tree_replay_text(as_of timestamptz DEFAULT NULL, query_width int DEFAULT 60)` | The same, indented, in `lock_tree_text()`'s layout. For reading about an incident at 4pm rather than during it. |
| `lock_tree_sampling_advice(since interval DEFAULT '7 days')` | A suggested interval for the sample cron entry, sized on the **widest queue in the window** rather than on the queue at this instant, with the reasoning and both inputs returned. |
| `lock_tree_age(interval)` | Compact interval rendering: `4s`, `1m30s`, `2h05m`. |
| `lock_tree_mode_short(text)`, `lock_tree_state_short(text)` | `AccessExclusiveLock` becomes `AX`, `idle in transaction` becomes `idle-in-tx`. Unknown values pass through unchanged rather than being guessed at. |

The view's columns and values are always full and unabbreviated. Shortening is opt-in, in the
text functions only, so anything selecting from the view or grepping for `AccessExclusiveLock`
keeps working.

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
| Incident | `lock_tree` (view), `lock_tree_roots()`, `lock_tree_text()`, `lock_tree_text_short()`, `lock_tree_lines()`, `lock_tree_wide()`, `lock_tree_summary()`, `lock_tree_actions()`, `lock_tree_command()` |
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
- **`lock_tree_policy_key()`**, new in 1.1.16. It is the shared definition the two alert functions
  call so that they agree; its text is the state key in `lock_tree_alert`, which is internal state.
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

- **The four tables are not registered for `pg_dump`.** That is a decision with reasons in
  [Backups and restores](../INSTALL.md#backups-and-restores), pinned by a test, and a future release may
  register them behind a documented option. `lock_tree_history_archive` is a fourth, kept out on the
  same reasoning: it describes pids and timestamps that mean nothing on the server a restore lands on.
- **`lock_tree_history_archive` is not read by any shipped function.** It exists so a scheduled job can
  move old history out in small batches; every read function still reads `lock_tree_history` alone. A
  `since` window therefore stops at the hot boundary rather than erroring, which is a limitation you
  can hit without being told, so it is stated here as well as on the table.
- **Cross-database visibility.** Each database has its own history. A fan-out sampler is a separate
  tool; see the [roadmap](roadmap.md).
- **Anything about a server where `make install` is not possible**, such as RDS and Aurora. Being pure
  SQL is what makes it plausible and nothing more.
