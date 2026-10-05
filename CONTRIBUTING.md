## Development

```bash
make prove              # 409 pgTAP tests against the server your libpq env vars point at
make check-install      # verify an installation
make demo               # the scripted incident
make scenarios          # all eight scenarios, both tools, output captured
make lint-docs          # the docs still match the code
make check-alert        # prove a real NOTIFY reaches a real listening client
make check-deadlock     # prove a real deadlock moves the counter and the sample records it
make check-deadlock DEADLOCK_TIMEOUT=15s   # same, with s6's timeout: proves the cycle AND the counter
make bench-history      # time the read side against a synthetic 1.2M row history (truncates it)
make check-upgrade      # every upgrade path ends in the same objects as a fresh install
make check-schema       # install into a private schema, then use it from a caller that cannot see it
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
| `test/16_duration_resolved.sql` | the resolution notices: nothing on a quiet database, one when an alerted root leaves the tree, and that a root which never alerted produces nothing |
| `test/17_duration_by_application.sql` | per-application blocking time, and the two directions in which it and the per-query figure invert: different statements in one application, and the same statement across two applications. Its expectations are derived from the sample rows rather than from the function under test, because a version that computed them from the same join agreed with a bug in it |
| `test/18_replay.sql` | replaying an incident that has ended: the nearest-sample rule, tie-breaking, a target before the first sample, and the columns replay carries that the live view does not, asserted **by name** so adding one is noticed |
| `test/19_index_usage.sql` | the read side SEEKS rather than filtering over the whole index. Reads the installed function definitions, so it holds for an extension installed from a tarball as well as from git. A first draft asserted on query plans here and failed CORRECTLY: on a 600 row fixture a sequential scan is the better plan, so the assertion was demanding a worse one |
| `test/21_redaction.sql` | the credentials `lock_tree_redact()` must catch, including the five it missed in 1.0.0: a real SCRAM verifier with its iteration count, an empty dollar tag, a newline inside the literal, a statement truncated by `track_activity_query_size`, and `U&'x'` or a comment before the literal. Plus all six states of `lock_tree.history_query`, and which of them fail safe |
| `test/22_schema_install.sql` | installed in a private schema: nothing lands in `public`, the two `search_path`-pinned functions qualify every sibling, and no object sits outside the schema the extension was installed into. The end-to-end half is `scripts/check-schema.sh`, because that needs a second database |

CI runs the same suite on all six versions. Three files each need a server setting the matrix
images provide (`max_prepared_transactions`, `shared_preload_libraries` for `pg_cron` and
`pg_stat_statements`) and skip themselves where it is absent, rather than failing a build that
was never going to work. None is a runtime requirement: `pg_lock_tree` itself needs no
`shared_preload_libraries`, and the rest of the suite runs without them.
