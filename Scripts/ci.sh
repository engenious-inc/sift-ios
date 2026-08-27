#!/bin/bash
# Sift local CI gate. Every phase of the round-2 improvement plan merges only
# when this script exits 0. CI (.github/workflows/ci.yml) runs the same script.
#
# Optional stages activate via environment:
#   SIFT_TEST_SSH_PORT/_USER/_KEY   — local-sshd integration tests
#   SIFT_TEST_BULK_BINARY           — discovery test against a real built bundle
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Resolving package dependencies"
swift package resolve

echo "==> Building (tests included)"
swift build --build-tests

echo "==> Running tests"
swift test

echo "==> ci.sh: all gates green"
