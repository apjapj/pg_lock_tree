# Security policy

## Supported versions

| Version | Supported | Why |
|---|---|---|
| 1.4.0 | **yes** | the current release; adds `lock_tree_deadlock_cycle()`, a new read function only |
| 1.3.0 | yes, by updating | adds `lock_tree_root_holds()`, a new read function only |
| 1.2.1 to 1.1.12 | yes, by updating | `ALTER EXTENSION pg_lock_tree UPDATE`; 1.2.1 changes only the `lock_tree_roots()` body and returns the same rows and columns as 1.2.0 |
| 1.1.11 | **no** | cannot be installed with `make install`; updating *through* it removes `EXECUTE` grants on two functions (INSTALL.md says how to restore them) |
| 1.1.10 and earlier | no | update to 1.3.0 |

Fixes are made on `main` and released as a new version. Released tags are not edited.

## Reporting a vulnerability

**Do not open a public issue.** There are two ways to report privately, and either is fine.

**By e-mail: linux.postgres+pg_lock_tree@gmail.com.** This works today, and it keeps working: the
address does not depend on anything about this repository.

**By GitHub:** the **Report a vulnerability** button, on this repository's Security tab, under
Advisories. A report there is a private advisory that only you and the maintainers can see, and you
are credited on it. GitHub offers this on public repositories only, so it appears here once this
repository is public; the e-mail above is the channel that works either way.

Either way, please include the pg_lock_tree version (`SELECT extversion FROM pg_extension WHERE extname =
'pg_lock_tree'`), the PostgreSQL major version, the roles the statements ran as and its grants, and the
smallest set of statements that shows the problem.

You will get an acknowledgement within 7 days. This is a small project maintained in spare time, so
there is no fixed date for a fix; you will be told what is planned, and credited in the CHANGELOG
unless you ask not to be.

## What counts

pg_lock_tree is pure SQL and runs inside the database with the privileges INSTALL.md describes, so the
issues that matter most are about privilege:

- a role reading something its grants should hide, for example another user's query text without
  `pg_read_all_stats`;
- `lock_tree_sample()`, the one `SECURITY DEFINER` function, usable to do more than insert its fixed
  column list, to read unredacted query text, or to run code as its owner (its `search_path` is pinned
  to `pg_catalog`, and so is that of `lock_tree_redact()`, which it calls);
- a role able to page people, write history or change thresholds without the grant INSTALL.md says it
  needs;
- an update script that changes or drops grants silently (as 1.1.11 did, and which is documented).

Lock data shown to a role that is entitled to see it is not a vulnerability, and neither is a monitoring
query's cost on a large server; those are ordinary issues.
