# reference: one object, one answer

**For: someone who knows which function they want and wants its columns.** Every object the extension
creates, the stability statement, and the NOTIFY payload keys.


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
| `lock_tree_lines(query_width int, short boolean)` | The renderer behind `lock_tree_text()` and `lock_tree_text_short()`. Exposed so the width comparison in `scenarios/s4` can attribute the saving to each abbreviation separately, which is the only way to tell a shorter mode from a shorter column |
| `lock_tree_actions()` | A written description of each root blocker and its blast radius, ordered by how many sessions each unblocks. Prose only, no runnable statements. `SET lock_tree.actions = off` suppresses it. |
| `lock_tree_command()` | One complete, runnable statement per root blocker, for pasting or for `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can work. |
| `lock_tree_history` (table) | Sampled trees, one row per session per sample. Empty until you schedule a sample. `query_id` on root rows only, since a blocked query has none. |
| `lock_tree_deadlock` (table) | `pg_stat_database.deadlocks` sampled on its own beat, whether or not anything is blocked. Naming no participants: the two statements are in the server log. Pruned by `lock_tree_prune()`. |
| `lock_tree_sample()` | Take one snapshot into `lock_tree_history`. Returns rows written, 0 when nothing is blocked. Nothing calls it for you. |
| `lock_tree_incidents(max_gap interval DEFAULT '5 minutes', since interval DEFAULT NULL)` | The history grouped into incidents: when each ran, peak sessions blocked, deepest chain, longest wait, and the root pids and application names involved. `since` bounds the window and defaults to `NULL`, meaning the whole retained history; on a long retention, pass it. |
| `lock_tree_prune(older_than interval)` | Delete history older than the given age, return how many **history** rows went, which is what it has always returned. The table only grows otherwise. |
| `lock_tree_history_size()` | What the history costs now and what it will cost at the rate it is already being written: rows, samples, total bytes, the observed sample interval, bytes per day, and days until it reaches a gigabyte. |
| `lock_tree_prune_batched(older_than interval, batch_size integer)` | A **procedure**, not a function. The same prune in committed batches, so no single lock is held for the whole of it. Cannot be called inside a transaction block, and checks for one before deleting anything. |
| `lock_tree_wide()` | One row per root instead of one per session: how many sessions each blocks, the deepest chain under it, the longest wait, and what they are waiting for. Use when the tree is too wide to read. |
| `lock_tree_summary()` | One row for the whole queue: sessions blocked, roots, deepest chain, longest wait, oldest root transaction. Zeros on a quiet database, not no rows, so it drops straight into a dashboard. |
| `lock_tree_statements()` | Per root, what `pg_stat_statements` already knows about the query holding the lock: normalised text, calls, mean and total time. Groups incidents by query rather than by pid. Optional; see below. |
| `lock_tree_notify(channel, min_blocked, min_depth, min_wait)` | Raise a `NOTIFY` when a chain is bad enough, and remember it so the same incident notifies once rather than on every sample. Escalates on more sessions, more depth, or a longest wait that has **doubled**. Returns how many it raised, so zero is the normal result. |
| `lock_tree_notify_resolved(channel, min_blocked, min_depth, min_wait)` | Raise one `NOTIFY` with `event: "cleared"` per root that **had alerted** and has now left the tree, then forget the stored state so the next incident alerts from the start. Same thresholds as `lock_tree_notify()`, and it reads and writes the same rows. Optional; see below. |
| `lock_tree_deadlocks(since interval DEFAULT '7 days')` | When `pg_stat_database.deadlocks` moved: the cumulative counter, how far it moved, whether it was reset, and the window total. Names no participants; the timestamp is how you find the log entry, and the history may hold them (see [What it cannot tell you](after-the-incident.md#what-it-cannot-tell-you)). |
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
  tool; see the [roadmap](roadmap.md).
- **Anything about a server where `make install` is not possible**, such as RDS and Aurora. Being pure
  SQL is what makes it plausible and nothing more.
