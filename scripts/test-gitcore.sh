#!/bin/bash
# The GitCore gate: `swift test` in GitCore/ at a bounded parallel width.
#
#   bash scripts/test-gitcore.sh [swift test arguments…]
#
# Swift Testing runs every test at once by default, and that saturates the cooperative thread
# pool inside the test process: each `await` then waits for a thread, and tests that time
# their own work fail on queueing, not on their work (E1 survey S15–S18; 28 external `yes`
# loops did not reproduce it). A width of 8 was green in every run measured and faster than
# unbounded. The variable is Swift Testing's experimental one, so the tests must also pass
# without it: every task still runs one plain, uncapped `swift test`.
#
# GITTER_TEST_WIDTH overrides the width. Prints the width and the run's total wall time, and
# exits with `swift test`'s status.
set -u

WIDTH=${GITTER_TEST_WIDTH:-8}
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=$WIDTH

cd "$(dirname "$0")/../GitCore" || exit 1
echo "width $WIDTH"
start=$(date +%s)
swift test "$@"
status=$?
echo "total $(( $(date +%s) - start )) s"
exit $status
