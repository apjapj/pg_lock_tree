# roadmap: what is planned, and what was considered and dropped

Organised by what the evidence supports rather than by release, and every item says how we know.
Work that has been done is in the last section, so this one is only ever about what is outstanding.

## Making the repository public

Drafted 2026-10-10 from the state of the repositories that day, not from memory: the flattened history
is pushed to GitHub (117 commits on `main`, CI green); GitHub has **no tags** and all four repositories
are **private**, with no description, no topics, and the licence shown as "NOASSERTION"; Forgejo and the
local clone carry 33 tags, 16 of them `v0.*`, whose deletion is on hold. Every v1.x tag is reachable from
GitHub's `main`, so pushing one uploads no history that is not already there.

**The paragraph above is the state of 2026-10-10 and is left as written.** It is a snapshot, and several
parts of it have since stopped being true. Each item below says what actually happened to it; where the
snapshot and an item disagree, the item wins.

**Checked 2026-10-19: all four repositories are public**, so the steps below that were gated on going
public are done. The one outward step still outstanding for this repository is the `v1.2.0` tag and its
GitHub Release; pg_bloat_cause has the same step outstanding as `v0.4.0`.

Marked **[Piotr]** where the step is outward-facing or cannot be taken back, and so needs his explicit
go; **[can do now]** where it is local, reversible, and can be reviewed before anything is pushed.

**Before anything is visible**

1. **[done, on main: Piotr chose to reword at HEAD and keep history] Internal names.**
   gitleaks over GitHub's `main` finds no secrets. It did find infrastructure: the `.forgejo/`
   workflows named the runner host, its runner and pool label, and two private addresses' last
   octets in comments, and the Forgejo host's private address was in `ci/Dockerfile`,
   `scripts/check-ci-github.sh` and the workflows. Every comment and document is reworded. Two
   names stay because they are functional in `.forgejo/workflows/test.yml`: the `runs-on` pool label,
   which must match the label the self-hosted runner registered, and the registry address the
   test image is pulled from. Removing them needs a generic runner label and a registry host name in
   pg-dev-infra's runner configuration, an infrastructure change for **[Piotr]**. History still
   holds the old names.
2. **[done, on main since 0c70e76, and green on GitHub] Secret scanning on GitHub.** It was written
   when `.github/workflows/` held only `test.yml` and the gitleaks history scan and detect-secrets ran
   on Forgejo only (`.forgejo/workflows/secrets.yml`); porting them was the work, so the public copy
   proves what Forgejo proves. That is done: `.github/workflows/` now carries `secrets.yml` as well,
   and the Forgejo twin was later added to the other three repositories so all four scan on both
   systems.
3. **[done, on main in all four repositories; GitHub now reports `PostgreSQL`] The licence GitHub cannot read.** `LICENSE` is the PostgreSQL License, but its text
   differs from the SPDX template enough that GitHub reports NOASSERTION. Match the template so it is
   detected as `PostgreSQL`; check after the push that the sidebar says so.
4. **[done, and confirmed 2026-10-19: SECURITY.md, an e-mail alias per repository plus GitHub's private vulnerability reporting, which is enabled on all four repositories] A security policy** at the repository root: how to report a vulnerability privately, and
   which versions are supported (1.1.13; 1.1.11 is not installable). The contact is Piotr's choice.
5. **[done in 1.1.14] README trim and badges.** The trim Piotr mentioned; a CI badge for the GitHub
   workflow (which renders now that the repositories are public); the `make install` needs a superuser
   shell and server headers, and the "managed instances (RDS, Aurora) are untested" caveat
   (INSTALL.md section C), both stated in the README rather than only in INSTALL.md.

   What the trim turned out to be: the README already routed by audience in "Where to go", and then
   listed all eleven documents flat underneath it, so a reader was routed and immediately shown
   everything anyway. The list is now grouped into read this first, read this when the situation
   arrives, and reference. Nothing was deleted. The badge was added and showed a broken image until the
   repositories went public, which was the accepted trade against a second commit later.
6. **[done in 1.1.14] Issue and pull request templates**, short: version, PostgreSQL version, output of
   `SELECT * FROM lock_tree_text()`; and CONTRIBUTING.md's md5 copy rule linked from the PR template.

   Written for pg_lock_tree, pg_bloat_cause and pg_limit_runway, each asking for its own text
   function. pg_incident_watch has none: it ships no extension, so there is no version to report.

   **Corrected 2026-10-12, because this item overclaimed.** When it was written only
   pg_lock_tree had a PR template, and only pg_lock_tree had a CONTRIBUTING.md, so "and
   CONTRIBUTING.md's md5 copy rule linked from the PR template" was true of one repository
   and implied true of three. pg_bloat_cause and pg_limit_runway now have both, each
   written against its own make targets and its own test counts rather than copied, and
   pg_incident_watch has a CONTRIBUTING and a bug report template of its own, the latter
   asking what is wrong rather than for a version. The templates also gained the YAML
   front matter GitHub needs before it registers a file as a template at all: without it
   the chooser offered nothing but a blank issue, on every repository, and nothing in CI
   could see it.
7. **[open, a small decision] `scripts/check-ci-github.sh`**: it is in `main` (7a80420), read run
   38068022236 correctly, and defaults to api.github.com with no host of its own; decide whether it
   stays a contributor script or moves to the umbrella.
8. **[done 2026-10-12, by Piotr] Release notes**, drafted from CHANGELOG.md's entry and published as
   GitHub Releases for v1.1.15 and v1.1.16. The v1.1.15 notes say plainly that v1.1.11 cannot be
   `make install`ed and is kept as a tag for the record.

**The outward steps, in this order, each [Piotr]**

9. **[done 2026-10-12, by Piotr] Tags to GitHub: `v1.1.15` and `v1.1.16`, and nothing else.** The
   earlier proposal here was `v1.0.0` to `v1.1.13`; it is withdrawn. Every local tag points at a
   commit already reachable from `github/main`, checked rather than assumed. Pushing them uploads no
   history that is not already on GitHub, so a tag adds a name and nothing else. What the seventeen
   would have cost is real: `on: push` has no branch filter, so every tag push triggers CI on both
   platforms, the Forgejo pool runs at capacity 1 so those runs serialise, and each one uses the
   workflows as they were at that old tag, which is why several would go red.

   **What is actually on GitHub: `v1.1.15` and `v1.1.16`**, named one at a time and never with
   `--tags`, each read green on both platforms before the next. The intermediate `v1.1.13` and
   `v1.1.14` never went to GitHub: they were superseded before the flip. Forgejo keeps every tag,
   including the `v0.*` ones: Forgejo is the archive, GitHub is the public release line. Someone
   wanting an old version from a GitHub clone uses the hash or fetches from Forgejo. **`v1.1.14` was
   never tagged anywhere, Forgejo and the local clone included**; its CHANGELOG section and its
   scripts are the only record of it. `v1.1.13` does exist on Forgejo and in the local clone, even
   though it never went to GitHub.
10. **[done 2026-10-12, by Piotr] The GitHub Release for each public tag**, from item 8's notes:
    v1.1.15 and v1.1.16 are both published; v1.1.16 is marked latest.
11. **[done 2026-10-11, by Piotr, in all four repositories] Description and topics**, for example "Lock trees, blocking history and alerts for
    PostgreSQL, in pure SQL" and `postgresql`, `postgresql-extension`, `locking`, `monitoring`.

    **Unblocked 2026-10-12:** the token gained the permissions it was missing, descriptions and
    topics are set on all four and read back, and repository-settings `PATCH` now answers 200.
    This also unblocks item 13 and, once the repository is public, private vulnerability reporting.
12. **[done: all four repositories are public] Visibility.** Flipping to public was Piotr's, in the
    GitHub settings. It is the step that cannot be taken back in practice: a public repository is
    cloned, forked and cached within hours.
13. **[done: a ruleset "protect main" carries the lint, the pgtap matrix and the install-path jobs as
    required checks, with one approving review] Branch protection and required checks** on `main`. The
    token used here was refused the protection API (403) while the repository was private, so this was
    done in the settings once it went public.
14. **[done: all four repositories are public, so the sibling links resolve] The umbrella and its
    siblings.** pg_incident_watch's README links all three tools; while they were private those links
    were 404s to a public reader.

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

  **Closed, and closed by the fix rather than by a better plan.** 1.1.5 stated the window bound on
  the waiter side of the join, and the 365-day fixture then confirmed it end to end: **1.9 s** at a
  year, against the 30.3 s projected here and the 2.3 s a week of retention cost under 1.1.2. The
  year is now cheaper than the week was. The projection went wrong for a reason worth keeping: it
  extrapolated a trend the fix had already removed, which is what a per-retention figure measured
  before a per-retention fix will always do.

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
  **The 365-day reading has been done, and the visibility map is refuted.** The fixture reported
`all-visible pages 1246773 of 1246773`, so autovacuum had kept up completely at 63 million rows and
  14 GB, and the `by_application()` plan reported `Heap Fetches: 0` on its root scan. The degradation
  this paragraph hypothesised was not present, so the hypothesis is wrong rather than merely unproven,
  and the suspect list is now empty rather than shorter: the waiter-side join was the whole of it.

  That does not make the effect impossible, it makes it a thing to watch rather than a thing to
  predict. It would need a table growing faster than autovacuum can keep up, which is a property of
  your write rate rather than of your retention, so it can still bite a busier installation at a
  week. The symptom is `Heap Fetches` climbing on a plan that should not need the heap, and the
  remedy is autovacuum settings on this one table rather than anything in the extension.

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
localhost. A dedicated runner label names it; `docker` is untouched, so `book-platform`,
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

  **Re-checked against a real year of history, and the rejection holds.** The 365-day fixture
  (63,072,020 rows, 3,153,601 samples, 14 GB) makes the case for partitioning weaker still, because
  the read side it would have degraded is already fast: a seven-day window costs 2.1 s through
  `duration()` and 1.9 s through `by_application()`. There is no 30 s read at a year to fix, that
  projection having been falsified, so partitioning would now be paying a measured 38% to 203%
  penalty on a query that costs two seconds. The retention benefit is real and is still bought with
  `TRUNCATE` where it can be, which is documented in
  [docs/history.md](history.md#retiring-old-history).
- **An archive table for old history, with BRIN, on a weekly cadence.** Measured on the 365-day
  fixture rather than assumed, and the interesting half is a negative result. The index shape is excellent:
  `corr(sampled_at, block) = 1.000000`, and BRIN on `sampled_at` is 1336 kB against 475 MB for the
  b-tree on the same 63M rows, while still serving a 30-day range. The shape does not pay for
  itself, for two reasons that only measurement would have found.

  Copying 61,862,400 rows, everything older than seven days, into a table in the same database took
  **298 seconds** and roughly doubled peak disk while it ran. And then the hot table still measured
  9740 MB, unchanged, because deleting rows does not return the file's high-water mark and a plain
  `VACUUM` does not either. So an archive built by deleting from the hot table costs a year of extra
  disk and five minutes of `ACCESS EXCLUSIVE`-adjacent work, and returns none of it. The only thing
  that returns space is `TRUNCATE`, and only on a table that is genuinely empty, which a table you
  intend to keep filling never is.

  Worth recording that the alerting path is not a factor in this at all: `lock_tree_notify()` reads
  `lock_tree_wide()` and `lock_tree_alert`, never `lock_tree_history`, and measures 6 to 24 ms on 63M
  rows. Keeping a year has never been in tension with alerting on it.

  **A cadence changes the verdict on the cost, and dissolves one of the objections.** Moving the
  whole year in one statement is 298 s; moving a week at a time is **1.8 s**, measured, with the peak
  disk penalty bounded by one week instead of the entire archive. More usefully, the high-water-mark
  objection does not apply to a table pruned on a fixed cycle: it grows to its window plus one cycle
  and is pruned back, so the high-water mark is the steady state and the file never exceeds it. That
  needs no `TRUNCATE` and no `ACCESS EXCLUSIVE` rewrite, which is the part this entry previously
  treated as unavoidable.

  What survives is the hot-set win and the API gap. A 30-day hot window on a weekly archive makes the
  hot table 2.8 GB instead of 28.1 GB, ten times smaller, for about two seconds of copying a week.
  Total disk is a wash. The costs, the BRIN recipe and the cadence arithmetic are all in
  [docs/history.md](history.md#retiring-old-history).

  **Shipped in 1.1.6, with the API gap left open on purpose.** `lock_tree_history_archive` and
  `lock_tree_archive()` are in the release, and this entry is the record of why the read functions
  were not changed with them: the 9.6 times slowdown on the root-to-waiter join, the 50% cost of an
  empty archive, and the fact that a boundary-spanning read cannot be a view because the sampler
  inserts into the history table. The remaining work is dedicated archive read functions, which is
  an API decision rather than a tuning one, and it sits in the open questions below rather than here.
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

- **A `source_host` column, so one archive can hold several hosts.** Asked for a review instance
  holding about a dozen production servers, and declined, on two measured grounds rather than taste.
  The value is the hard part: `inet_server_addr()` is the obvious candidate and returns **NULL over a
  unix socket**, verified on a scratch cluster built for the purpose, which is exactly how a local
  cron job calls `lock_tree_archive()`. `pg_control_system().system_identifier` works, is assigned
  at `initdb` and so survives restarts and container rebuilds; `cluster_name` is settable and **empty
  by default**, so forgetting it labels every host with the empty string. And a per-host partition
  is the wrong answer twice, once for the 38% to 203% the roadmap has already measured partitioning to
  cost the read side and once because a per-host partition is a schema-per-host under another name.
  The migration is the other reason: 1.1.6 shipped, so a filled archive has rows with no host value
  and `ADD COLUMN` gives NULL for all of them, starting the append-order exception for a column
  nobody needs. **One archive table per host, with the host in the table or schema name**, answers the
  scenario with no column and no migration. Storage for a dozen hosts is 0.33 TiB a year at
  production-shaped query text and 0.15 TiB at the fixture's, with BRIN costing 384 kB in total.
- **The `tool` key, and the shared alert contract.** Raised by the pg_incident_watch umbrella, which
  groups this extension with `pg_bloat_cause` and `pg_limit_runway` and promises that all three emit
  the same JSON payload shape so one listener can route all of them. The umbrella lists this as its
  own step 5, to be done "in that project, not here", and says to raise it on this roadmap. Raised,
  and not implemented, because the shared contract it depends on does not exist yet. That contract is
  to be written in the umbrella's own directory rather than in this repository, and inventing a
  payload shape here would produce exactly the local version the umbrella says not to invent.

  What is already compatible: this extension's stability rule is "NOTIFY payload keys: additive only",
  so adding `tool` is a minor release and not a break. Its `event` values are `alerting` and `cleared`
  today, and the umbrella wants `alerting`, `escalated`, `cleared`, with the open question of whether
  `escalated` is added here or the umbrella adopts these two. `escalated` is the only thing this
  extension would actually need to add, and its `lock_tree_alert` table already stores the value at
  the last notification, which is what an escalation edge has to compare against. **Blocked on the
  contract, not on anything here.**

  Two other umbrella notes worth recording rather than acting on. It flags that PG 14 reaches end of
  life on 2026-11-12 and recommends the umbrella floor at 15 while this extension keeps 14; and it
  asks for a job that installs all three extensions into one database, which is the only real test of
  "works alongside" and cannot exist until the other two do.
- **A recurrence report, and the fingerprint question it needed.** Asked for as "has this happened
  before, and is it getting worse", on the reasoning that a review instance is where it would run and
  speed does not matter there. Speed is not the obstacle: counting **every** incident in a 216,072-row
  archive takes 271 ms, and a bounded search on six times that takes 1.9 ms. The shape is.

  A fixture of 12 distinguishable incidents, 20 minutes each, queried the obvious way gives:

  ```
  tag           bursts   worst_wait
  incident_01      900   00:01:40
  ```

  **900 is not 900 recurrences.** It is one incident, sampled 900 times. Segmenting the same data on
  a 5-minute gap, which is what `lock_tree_incidents()` already does, gives 1, and 1 is the truth. A
  report that says 900 when the truth is 1 is worse than no report, because it is confidently wrong.

  **So the fingerprint question was the wrong question, and the data says so.** The candidates were
  `waiting_for`, `waiting_for + application_name` and `query_id`, with cardinalities of 12, 20 and 2
  distinct over 338,688 samples. But those cardinalities are a property of the fixture, and the first
  fixture built for this had 12 tags where every sample contained every tag, so every fingerprint gave
  the same answer. A fingerprint cannot be chosen from a fixture, because a fixture you design will
  confirm whatever you expected. What decides it is the incident segmentation, which is why the report
  has to be built on the gap logic rather than on a group-by.

  `query_id` cannot be the fingerprint and should not be offered as one: NULL on every waiter row and
  2 distinct values on a realistic archive, so it identifies a statement only on root rows, and a
  recurrence is made of waiter rows.

  The remaining question is a decision rather than a measurement. Against: the extension has no
  reporting features, and this would be the first. For: the archive was write-only until 1.1.8 and is
  now readable but still cannot answer the question it exists to answer.
- **The archive is never pruned by anything shipped.** `lock_tree_prune()` and
  `lock_tree_prune_batched()` do not touch it, deliberately, since it is a copy you made, so it only
  shrinks if you delete from it yourself and no function does that. It is stated on the procedure's
  `COMMENT` and in [docs/history.md](history.md#retiring-old-history). **Half closed in 1.1.7:**
  `lock_tree_history_size()` now reports `archive_bytes`, so the size is at least visible. Whether a
  prune for the archive should ship is still open, and the argument against is that deleting from a
  cold tier on a schedule is a policy choice the operator has to make, not a default.
- **An archive needs no re-scrub, and that is worth a second look.** 1.0.1 shipped a one-off `UPDATE`
  re-redacting rows written before 1.0.0, because until then the history kept whatever query text it
  was given. The archive has no equivalent and does not need one on the paths that exist, since the
  only supported way to fill it re-redacts on the way across. A direct `INSERT` bypasses redaction
  exactly as it does in the history. Recorded because the first person to find a credential in the
  archive will look for the scrub 1.0.1 has for the history.
- **`scripts/bench-history.sh` did not clear the archive** when it truncated the history to build a
  fixture. This entry said no timing was wrong because nothing read the archive; by the time it was
  fixed that was no longer true, since `lock_tree_history_size()` has reported `archive_bytes` since
  1.1.7 and `lock_tree_archive_find()` reads it since 1.1.8. **Closed after 1.1.10:** the script now
  truncates both tables, says so in the `--force` refusal, prints the archive's row count with the
  fixture, and refuses to time anything if it is not 0. Run for real with 5,000 rows planted in the
  archive first: they were cleared, the run reported `archive | 0 rows`, and every plan check passed.
  **Closed for `demo.sql` by deciding not to change it**, which is the opposite of what this entry
  previously said. `demo.sql` truncates `lock_tree_history` and never touches the archive, and that
  is correct: it reads the history, through `lock_tree_incidents()`, `lock_tree_history_statements()`
  and the duration functions, and it never reads the archive at all. So emptying the archive would
  destroy a year of someone's cold history while protecting no output of the demo's own.

  The difference from the benchmark script is that script *does* read the archive, in exactly one
  place: the `archive_bytes` column of `lock_tree_history_size()`, which the demo never calls. Every
  plan check it times is on `lock_tree_history`, not on the archive. That single read is why it must
  control the archive, and why it asks for `--force` to do so.

  What remains, as a separate change: `demo.sql` truncates `lock_tree_history` at lines 257 and 410,
  which is a real but smaller problem, since it clears a table the demo writes to but did not create.
  Its header says "Safe to re-run: everything it creates is terminated and dropped at the end", which
  is not quite true of that table, and the honest fix is for the header to say so rather than for the
  demo to destroy data it does not own.
- **What each root *holds* that its waiters want**, not only what the waiters ask for. The wait side is
  reported; the hold side is `pg_locks` and the lock tags, and the interesting version is a diff
  against what the waiter is asking for.
- **A `log_lock_waits`-style hook** naming both sides of a deadlock. The counter is recorded, and the
  two statements are in the server log with no attribution. A bigger change than it looks: it has to
  work on a server where nobody has installed anything.
- **`pg_tle` on RDS and Aurora**, where `make install` is not possible. Being pure SQL is what makes
  it plausible. The thing most likely to fail is whether `pg_blocking_pids()` is reachable under
  `pg_tle`, so that is what to check first.
- **A cheap `lock_tree_history_size()`**, which is the one function whose cost follows retention. It
  takes 6.3 s on the 365-day fixture (6.7 s when re-measured with its row count in 1.1.10), 5.0 s of which is `count(DISTINCT sampled_at)` over 63M rows. A
  `GROUP BY` rewrite measured 2.95 s on the same data, so this is a real saving and not a large one.
  **Partly done in 1.1.7**, which added `archive_bytes` and made a point of adding no column that
  needs a scan: an archive row count and its extrema would have cost 495 ms at 12.3M rows and given
  the function a second cost that follows retention, so they were measured and refused. What remains
  is the `count(DISTINCT)` itself, and the more useful change of what the function is for: it reports
  `pg_total_relation_size`, which is the file's high-water mark, so it cannot distinguish a table
  holding a week of rows in a year-sized file from one holding a year of them. That needs live rows
  rather than a size, which is a different figure with a different meaning, and it is a decision
  rather than a bug.
- **How large a history is too large.** Asked and answered, at least for a year, by building the
  fixture instead of reasoning about it. There is no single threshold, because retention and read
  speed are independent: the read functions cost what you ask for, not what you keep, so a 63M-row
  table answers a seven-day window in about two seconds. The binding constraint is disk, not query
  time, and it is a budget rather than a cliff. Three measured numbers now carry that section, in
  [docs/history.md](history.md#holding-more-than-a-few-weeks).

## Done, and where to read about it

Recorded here so the section is a record rather than a wish list. Each is one line because the
changelog has the detail and a test has the proof.

- **Reading across the archive boundary**, closed in 1.1.8 by `lock_tree_archive_find()`, which
  searches the archive and nothing else. Longer than a line, unlike the rest of this section,
  because the reasoning is what constrains any future attempt to span both tables: the measured
  96 ms to 924 ms regression, why it cannot be a view, and why the guard cannot be enforced from a
  SQL body. The changelog has the figures. The point here is that the boundary is now a property of
  a separate function rather than a silent truncation inside a shared one.

  **As of 1.1.6 the archive was write-only**: `lock_tree_history_archive` and `lock_tree_archive()`
  shipped, nothing read the archive, and a `since` window on any read function silently stopped at
  the hot table rather than erroring. That is history, and it is why this entry reads oddly at first.

  The obvious fix at the time was to teach the existing read functions to span both tables. It was
  measured and rejected: with the archive as a `UNION ALL` on the inner side of the root-to-waiter
  join the planner stops choosing the index probe, 96 ms to **924 ms** on the same data, and an
  **empty** archive still costs 50%, so installations that never archive would pay for a feature they
  do not use. It could not be a view either, since the sampler `INSERT`s into the history table and
  PostgreSQL refuses `cannot insert into view` for any view containing `UNION`.

  What shipped instead is `lock_tree_archive_find()`. The window is required because a NULL cannot
  become an index bound, and 1.1.9's message gives the corrected figures: on 5,184,000 archived rows
  spread over 7 to 67 days, a window reading 1,122,915 rows took 241 ms and no window over all
  5,184,000 took 319 ms.

  **1.1.8 shipped two false figures here** and the correction is recorded in CHANGELOG.md: its three
  fast windows matched zero rows, and its "did not finish in 10 minutes" was autovacuum contention.
  1.1.9 then called the index a small penalty at full coverage, and **that was wrong too**: it
  compared a single-backend bitmap scan with a two-worker parallel scan. Measured in 1.1.10 with the
  plan forced and nothing else changed, the bitmap scan wins at every coverage from 14% to 86%, and
  the function's own aggregation costs four to seven times the scan.

  The bound also cannot be enforced from a `LANGUAGE sql` body: three attempts at a guard failed
  while looking correct, the third because a guard joined into the query sits below the function's own
  `LIMIT` and a query returning no rows never reaches it. `LANGUAGE plpgsql` with the check as the
  first statement is forced, not chosen, and the VOLATILE that 1.1.8 called load-bearing turned out to
  be irrelevant to that shape.


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
  **Both halves were blind until 1.1.8 found them.** Their comment strip had no `n` flag, so a bare
  dot matched a newline and `$` anchored at end of string: `lock_tree_duration()` was reduced from
  7391 characters to 1 before the assertion read it, so it could not fail. Found by planting an
  unqualified `PERFORM` and watching a check report itself clean, which is the only way a check can be
  shown to still catch the defect it exists for.
- **The README's nine factual errors, and the split** into a short entry point plus `docs/` and
  `CONTRIBUTING.md`, with a link and anchor check so the moved sections cannot quietly break it again.
