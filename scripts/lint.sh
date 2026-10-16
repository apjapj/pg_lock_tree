#!/usr/bin/env bash
# scripts/lint.sh: every database-free check, in one script. No Makefile and no PostgreSQL.
#
# Why this is a script and not the `lint` recipe. `make lint` parses the Makefile first, and the
# Makefile includes $(PGXS) unconditionally, so `make lint` needs pgxs.mk to exist. A CI container
# can have pg_config and no server-dev package, and then `make lint` stops at the include and no
# check runs at all. A lint that needs a PostgreSQL toolchain to check shell scripts is the wrong
# dependency. `make lint` calls this, and both CI copies call it directly.
#
# It also closes a real gap: the two lint jobs ran `lint-docs.sh` alone, so `check-pg-matrix-claims.sh`
# (the Makefile's lint-matrix) never ran in CI. One script is the list.
#
# Everything here is text and git only: no database, no network, no superuser, so it is safe
# anywhere and cheap enough for a pre-commit hook.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

# Documentation, objects, paths, links, anchors, and the test table: the version agrees across
# control/README/CHANGELOG, every object and file the docs name exists, every test plan matches its
# assertions, and the house style rules hold.
step "the documentation's claims"
./scripts/lint-docs.sh
# A document that states the PostgreSQL range the matrix covers must state the range CI declares.
step "the stated PostgreSQL range"
./scripts/check-pg-matrix-claims.sh

echo
echo "run 'make prove' and 'make scenarios' against a server for the rest"
