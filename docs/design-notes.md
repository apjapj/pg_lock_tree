# design notes: why it is built this way

**For: maintainers, and for anyone who thinks a simpler thing would do.** Each note is an argument,
not a defence. Where the honest answer is "it would be better but PostgreSQL will not allow it", that
is what it says.

**The table below is the index; the sections after it are the exceptions.** Every argument the
extension has a decision about is argued on the page a reader arrives at for some other reason, so
that the reasoning is where it is needed. This file indexes those, because the alternative is
reading four files to find out whether an argument exists at all. Three of them had no page to live
on and are written out at the end.

| Question | Where the answer is |
|---|---|
| Why does the tree fill a queue instead of a list? | [What it looks like](../README.md#what-it-looks-like) |
| Why does the root have to be named? | [What it looks like](../README.md#what-it-looks-like), on `root_object` and the pid 0 trap |
| Why is there a wide form and a summary? | [docs/incident.md](incident.md#when-the-queue-is-too-wide-to-read) |
| Why is blocking time summed from gaps? | [docs/incident.md](incident.md#which-query-is-costing-the-most-time) |
| Why per-application as well as per-query? | [docs/incident.md](incident.md#which-application-is-costing-the-most) |
| Why is alerting on onset and not on every sample? | [docs/alerting.md](alerting.md#why-it-does-not-notify-on-every-sample) |
| Why does escalation compare against the last notification? | [docs/alerting.md](alerting.md#why-the-wait-escalates-by-doubling-and-not-by-growing) |
| Why does a deadlock counter get its own table? | [docs/after-the-incident.md](after-the-incident.md#why-the-counter-is-sampled-into-its-own-table) |
| Why can a deadlock report usually not name the two statements? | [docs/after-the-incident.md](after-the-incident.md#what-it-cannot-tell-you) |
| Why is redaction on by default, and what does it refuse? | [docs/history.md](history.md#redaction) |
| Why do the samples have to be separate statements? | [docs/history.md](history.md#one-hazard-worth-knowing-before-you-schedule-anything) |
| Why is nothing registered for `pg_dump`? | [INSTALL.md](../INSTALL.md#backups-and-restores) |
| Why is the history not partitioned? | [docs/roadmap.md](roadmap.md#considered-and-not-planned) |
| Why is column order not guaranteed? | [docs/roadmap.md](roadmap.md#considered-and-not-planned) |
| Why is a cross-database view not planned? | [docs/roadmap.md](roadmap.md#considered-and-not-planned) |
| Why is the sample time `statement_timestamp()` and not `clock_timestamp()`? | [`test/19_index_usage.sql`](../CONTRIBUTING.md#tests), and the 0.15 entry in [the changelog](../CHANGELOG.md) |

## The three arguments that had no page to live on

### Why redaction replaces to the end of the statement

`lock_tree_redact()` replaces from the opening of the password literal to the **end of the text**
rather than to the closing quote, because a statement truncated by `track_activity_query_size` has no
closing quote to find. It also matches `$` with an empty tag, a newline inside the literal, and
`U&'x'` or a comment between `PASSWORD` and the literal.

That over-redacts the tail: `PASSWORD 'p', VALID UNTIL '2026-01-01'` loses the `VALID UNTIL` clause
too. The clauses that can follow a password are `VALID UNTIL` and `IN ROLE`, neither of which is what
an incident is diagnosed from, so that is the right side to err on. It is asserted in
`test/21_redaction.sql` so it cannot later be mistaken for a bug.

The first version of this pattern claimed it "could not under-redact", and it could: a real SCRAM
verifier has a `:` after its iteration count that the character class could not get past. The claim
was wrong and is corrected in place in [the changelog](../CHANGELOG.md) rather than edited out.

### Why column order is not guaranteed

`ALTER TABLE ADD COLUMN` appends, so a database older than 0.8 keeps `root_object` at the end of the
row of `lock_tree_history` and `lock_tree_alert` and displaces what followed it. No update script
rebuilds those tables, because rebuilding the history would need twice the disk and hold
`ACCESS EXCLUSIVE` for the length of the copy, which is a worse outcome than a column order nobody
relies on.

`scripts/check-upgrade.sh` proves this rather than asserting it: every upgrade path is compared
against a fresh install, and the position difference is a named exception that is **checked in both
directions**. A path that drifts on an unlisted column fails, and so does a run where no path drifts
on the listed ones, which is what stops the list rotting into a permanent exemption.

So `SELECT *` on the tables is outside the contract. Name your columns. The view is the interface
and it names all of them. The decision is in
[docs/roadmap.md](roadmap.md#considered-and-not-planned); what is here is the reason the exception
is safe.

### Why two functions pin `search_path` and the rest do not

`lock_tree_sample()` pins it because it is `SECURITY DEFINER` and reads every session's query text
through `pg_stat_activity`. `lock_tree_redact()` pins it because `lock_tree_sample()` inlines it,
being `IMMUTABLE`.

A pinned `search_path` is the correct choice for both and the only situation in which an
**unqualified** call to a sibling fails, since `pg_catalog` is the whole path. Everywhere else the
caller has the extension's schema on its path, so an unqualified reference resolves anyway and the
mistake is invisible until somebody installs into a private schema.

That is the whole argument for `test/22_schema_install.sql` and `scripts/check-schema.sh`: they exist
to make the one case visible. The header of the test records what has and has not been proved about
it.