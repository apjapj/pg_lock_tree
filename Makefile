# pg_lock_tree Makefile
EXTENSION = pg_lock_tree
DATA      = pg_lock_tree--0.1.sql pg_lock_tree--0.2.sql pg_lock_tree--0.3.sql pg_lock_tree--0.4.sql pg_lock_tree--0.5.sql pg_lock_tree--0.6.sql pg_lock_tree--0.7.sql pg_lock_tree--0.8.sql pg_lock_tree--0.9.sql pg_lock_tree--0.10.sql pg_lock_tree--0.11.sql
PGFILEDESC = "pg_lock_tree - readable lock-wait trees"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Update scripts (pg_lock_tree--0.1--0.2.sql) must be installed as well, but they must NOT go
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

# The checks that need no server. Safe as a pre-commit gate; `prove` and `demo` are not,
# since they need a live PostgreSQL with the extension installed.
check: lint-docs
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
	./scripts/check-deadlock.sh