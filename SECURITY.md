# Security policy

## Supported versions

| Version | Supported | Why |
|---|---|---|
| 1.1.13 | **yes** | the current release |
| 1.1.12 | yes, by updating | installs the same objects as 1.1.13; `ALTER EXTENSION pg_lock_tree UPDATE` |
| 1.1.11 | **no** | cannot be installed with `make install`; updating *through* it removes `EXECUTE` grants on two functions (INSTALL.md says how to restore them) |
| 1.1.10 and earlier | no | update to 1.1.13 |

Fixes are made on `main` and released as a new version. Released tags are not edited.

## Reporting a vulnerability

**Do not open a public issue.** Report it privately, by either:

- GitHub's **Report a vulnerability** button on this repository's Security tab (a private advisory
  visible only to the maintainers), or
- e-mail to **SECURITY-CONTACT-TO-BE-SET**.

Please include the pg_lock_tree version (`SELECT extversion FROM pg_extension WHERE extname =
'pg_lock_tree'`), the PostgreSQL version, the role the statements ran as and its grants, and the
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
