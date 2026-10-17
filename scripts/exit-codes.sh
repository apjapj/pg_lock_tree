#!/usr/bin/env bash
# The exit codes our check scripts return, in one table, so a script and the defect cell that runs it
# cannot drift apart.
#
# Why a shared file. check-alert.sh exits 3 to mean "could not run", and the defect cell that runs it
# declares could_not_run_exit_codes=3 so that a setup failure is could-not-run and never a catch.
# Those are the same fact told in two files, and they could move apart with nothing to notice.
# They live here instead:
#
#   * check-alert.sh reads the numbers it exits with from this file; and
#   * check-defects.sh reads it to check that a command cell's could_not_run_exit_codes names a code
#     this file declares, so a cell cannot claim a code the script does not use.
#
#   0  the checks passed
#   1  the checks ran and something failed
#   3  the checks could not run: no server, or the extension is not installed
#
# Numeric, not an enum: an exit status is a number and the harness reads the number.
EXIT_PASS=0
EXIT_FAILED=1
EXIT_COULD_NOT_RUN=3

# The codes that mean "did not run". A command cell's could_not_run_exit_codes must be a subset of
# these, or check-defects.sh reports the cell as malformed rather than letting a setup failure be
# credited as a catch.
EXIT_COULD_NOT_RUN_CODES="3"
