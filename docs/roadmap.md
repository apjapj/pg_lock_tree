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
