# ci/Dockerfile: the server image pg_lock_tree's GitHub CI runs.
#
# The Forgejo workflow pulls apjapj/pg-test from the Forgejo host's registry, which is private and a
# GitHub-hosted runner cannot reach. So this builds from the official postgres image instead, which
# is public and carries everything the suite needs except pgTAP.
#
# Nothing here is private, so a public runner can build it. Locally the Forgejo images still work and
# the local workflow is untouched.
#
# What the suite needs and where it comes from:
#
#   pgTAP                apt: postgresql-<major>-pgtap. Not in the official image.
#   pg_cron              apt: postgresql-<major>-cron. Also NOT in the official image, which is worth
#                        stating because it looks like it should be: the image ships dblink and
#                        pg_stat_statements but not pg_cron, and asking for pg_cron in
#                        shared_preload_libraries without installing it stops the server at startup with
#                        "could not access file pg_cron.so". test/06_cron.sql, test/07_history.sql and
#                        test/14_deadlocks.sql all skip themselves without it, so the suite would pass
#                        while testing nothing that it is supposed to test.
#   dblink               in the official image already; 20 of the 23 pgTAP files and demo.sql use it
#   pg_stat_statements   in the official image already
#
# max_prepared_transactions is deliberately NOT set here. It has to go in the server's command line,
# because a Dockerfile cannot set it for a running server and a GitHub service container has no
# `command:` override. ci/server.sh does it, and asserts it took.
#
# Build with:  docker build --build-arg PG_MAJOR=18 -f ci/Dockerfile -t pg-lock-tree-ci:18 .
# The image tag and the apt package version are NOT the same string, and assuming they are breaks the
# one version this suite must test that nobody can skip. The Docker Hub tag for the current beta is
# 19beta4; the Debian package inside it is postgresql-19. Asking apt for postgresql-19beta4-pgtap fails
# with "Unable to locate package", which stopped the matrix at its last version with an error that
# reads like a network problem. Hence two arguments.
#
# Build with:
#   docker build --build-arg PG_MAJOR=19beta4 --build-arg APT_MAJOR=19 \
#     -f ci/Dockerfile -t pg-lock-tree-ci:19beta4 .
ARG PG_MAJOR=18
ARG APT_MAJOR=
FROM postgres:${PG_MAJOR}
ARG APT_MAJOR
# Defaults to the image tag, which is right for every released version.
# WITH_MAKE adds `make`, and only the install-path-checks job needs it. That job exists to test
# `make install`, which is the command that was broken in v1.1.11 and shipped anyway, so it has to run
# the real thing rather than a shell script that copies files into the same place. pg_config and
# pgxs.mk are already in the official image, so `make` alone is the whole gap; it is behind a flag
# because the six matrix jobs have no use for it.
ARG WITH_MAKE=0
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "postgresql-${APT_MAJOR:-${PG_MAJOR}}-pgtap" \
      "postgresql-${APT_MAJOR:-${PG_MAJOR}}-cron" \
 && if [ "$WITH_MAKE" = 1 ]; then \
      apt-get install -y --no-install-recommends make; \
    fi \
 && rm -rf /var/lib/apt/lists/*