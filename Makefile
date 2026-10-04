# pg_lock_tree — Makefile
EXTENSION = pg_lock_tree
DATA      = pg_lock_tree--0.1.sql pg_lock_tree--0.2.sql
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

# Scenario suite: seven incidents, each queried both by pg_lock_tree and by the published
# recursive CTE, with both outputs captured. Needs a superuser.
scenarios:
	./scenarios/run.sh