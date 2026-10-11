# pg_lock_tree Makefile
EXTENSION = pg_lock_tree
DATA      = pg_lock_tree--1.0.0.sql pg_lock_tree--1.0.1.sql pg_lock_tree--1.0.2.sql pg_lock_tree--1.1.0.sql pg_lock_tree--1.1.1.sql pg_lock_tree--1.1.2.sql pg_lock_tree--1.1.3.sql pg_lock_tree--1.1.4.sql pg_lock_tree--1.1.5.sql pg_lock_tree--1.1.6.sql pg_lock_tree--1.1.7.sql pg_lock_tree--1.1.8.sql pg_lock_tree--1.1.9.sql pg_lock_tree--1.1.10.sql pg_lock_tree--1.1.11.sql pg_lock_tree--1.1.12.sql pg_lock_tree--1.1.13.sql pg_lock_tree--1.1.14.sql pg_lock_tree--1.1.15.sql pg_lock_tree--1.1.16.sql
PGFILEDESC = "pg_lock_tree - readable lock-wait trees"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Update scripts (pg_lock_tree--1.0.0--1.0.1.sql) must be installed as well, but they must NOT go
# in DATA: PGXS copies DATA entries by name, and an update script needs its own name on disk
# so PostgreSQL can find it for ALTER EXTENSION ... UPDATE. Listing it in DATA works for the
# full version files precisely because those names are what PostgreSQL looks for; an update
# path is found by a different convention, so install it explicitly instead.
UPGRADES = $(wildcard $(srcdir)/pg_lock_tree--*--*.sql)

install: install-upgrades

install-upgrades:
	@if [ -n "$(UPGRADES)" ]; then \
	  for f in $(UPGRADES); do \
	    $(INSTALL_DATA) "$$f" '$(DESTDIR)$(datadir)/extension/' || exit 1; \
	  done; \
	fi

# Run the pgTAP suite against an already-installed extension.
# Override connection with standard libpq env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD).
TESTDB ?= postgres
prove:
	pg_prove --dbname $(TESTDB) test/*.sql


# Every target here is procedural: none of them produces a file of its own name, so all of them are
# phony. Without this, `make scenarios` sees the scenarios/ directory, decides the target is already
# up to date, and does nothing at all, which it did until this line existed. A target that silently
# does nothing is worse than a broken one, because the documentation says it captures output.
.PHONY: install install-upgrades prove demo check-install scenarios lint-docs capture lint check-alert explain-alert check-deadlock bench-history check-upgrade check-schema check-examples check-ci

# See the extension work on a real blocking chain: rebuilds the nightly-batch incident
# with dblink, shows the tree, the roots and the actions, then cleans up after itself.
# Needs a superuser and the dblink contrib module.
demo:
	psql -X -f demo.sql

# Verify an installation: server version, extension version, every object present, every
# function callable, and the prepared-transaction setting. Run it as your monitoring role as
# well as yourself, which is how you confirm the grants rather than assuming them.
check-install:
	./scripts/check-install.sh

# Scenario suite: seven incidents, each queried both by pg_lock_tree and by the published
# recursive CTE, with both outputs captured. Needs a superuser.
scenarios:
	./scenarios/run.sh

# Check that the documentation's factual claims still hold: the version agrees across
# control/README/CHANGELOG, every object and file the docs name exists, every test plan
# matches its assertions, and the house style rules hold. Pure text, no database, so it
# is cheap enough to run before every commit.
lint-docs:
	./scripts/lint-docs.sh

# Write the documentation examples that are captured rather than written, and apply the mask that
# makes two runs comparable. Needs a server with the extension installed, so it is not part of
# 'make lint': run it after changing anything that prints, and commit what it writes.
capture:
	./scripts/capture.sh

# The checks that need no server. Safe as a pre-commit gate; `prove` and `demo` are not,
# since they need a live PostgreSQL with the extension installed.
lint: lint-docs
	@echo "run 'make prove' and 'make scenarios' against a server for the rest"

# Prove that lock_tree_notify() actually delivers a NOTIFY a listener can read, and explain what
# one means. A script rather than a pgTAP file because psql prints notifications to stdout and a
# TAP assertion cannot see stdout, so the delivery path needs a real second client. Needs a server
# and superuser.
check-alert:
	./scripts/check-alert.sh

# Just the explanation, from a payload you paste. No database and no superuser needed, which is the
# point: the first thing you do at 3am should not be something that can fail.
explain-alert:
	@./scripts/check-alert.sh --explain '$(PAYLOAD)'

# Prove that a real deadlock moves pg_stat_database.deadlocks and that the sample records it. A
# script rather than a test file because the increment lands when the server breaks the cycle, on a
# timer, and three separate attempts to observe it inside a single psql session all failed. Needs a
# server and superuser.
check-deadlock:
	./scripts/check-deadlock.sh $(if $(DEADLOCK_TIMEOUT),--deadlock-timeout=$(DEADLOCK_TIMEOUT),)
# The read-side benchmark. It TRUNCATEs lock_tree_history and the archive to build a known fixture, so it
# passes --force itself rather than relying on you having read this comment. Needs a server.
bench-history:
	./scripts/bench-history.sh --force $(if $(DAYS),--days=$(DAYS),) $(if $(EVERY),--every=$(EVERY),) $(if $(SESSIONS),--sessions=$(SESSIONS),) $(if $(KEEP),--keep,)

# Proves that every upgrade path ends in exactly the same objects as a fresh install. Creates and
# drops databases, so it needs a server you are willing to have it create databases on. It is not in
# `make prove` because it is a release check, not a unit test: the tests run against whatever is already
# installed and would pass on an update path that had never been executed.
check-upgrade:
	./scripts/check-upgrade.sh

# The release gate. Reads CI for a commit and refuses unless every workflow is green.
#
# NOT in `make lint`, and that is deliberate rather than an oversight: it needs the network, a
# Forgejo token and the commit to be pushed, so folding it in would make the offline lint fail for a
# reason that has nothing to do with the documentation. It is a gate on publishing, not a check on
# the tree, and a gate that can only run in one place is a gate that gets skipped.
check-ci:
	./scripts/check-ci.sh

# The non-public schema install. It creates and drops a scratch database, so it is a script and not a
# pgTAP file, and it is not in `make prove`. test/22_schema_install.sql covers the structural half.
check-schema:
	./scripts/check-schema.sh

# Do the SQL examples in the documentation still work? Needs a server with the extension installed,
# which is why it is not in `make lint`; run it beside `make prove`.
#
# It exists because `SELECT * FROM lock_tree_replay(42)` sat in docs/after-the-incident.md since
# 0.14 and lock_tree_replay() has only ever taken a timestamptz. Nothing executed the examples, so
# nothing noticed.
check-examples:
	./scripts/check-examples.sh
