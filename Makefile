# pg_lock_tree — Makefile v0.1
EXTENSION = pg_lock_tree
DATA      = pg_lock_tree--0.1.sql
PGFILEDESC = "pg_lock_tree - readable lock-wait trees"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Run the pgTAP suite against an already-installed extension.
# Override connection with standard libpq env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD).
TESTDB ?= postgres
prove:
	pg_prove --dbname $(TESTDB) test/*.sql
