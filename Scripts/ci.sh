#!/bin/bash
# Sift CI gate. Every phase merges only when this script exits 0.
#
#   ./Scripts/ci.sh          fast gate: resolve + build + unit/CLI tests
#   ./Scripts/ci.sh --full   adds a throwaway local sshd (SSH integration tests),
#                            the fixture Xcode project build, and a real
#                            enumeration-discovery check (needs an iOS simulator)
#
# Extra env respected by the test suite:
#   SIFT_TEST_SSH_PORT/_USER/_KEY  — external sshd instead of the throwaway one
#   SIFT_TEST_BULK_BINARY          — symbol-discovery test against a real bundle
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

echo "==> Resolving package dependencies"
swift package resolve

echo "==> Building (tests included)"
swift build --build-tests

SSHD_DIR=""
cleanup() {
  if [ -n "$SSHD_DIR" ] && [ -f "$SSHD_DIR/sshd.pid" ]; then
    kill "$(cat "$SSHD_DIR/sshd.pid")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "$FULL" = 1 ] && [ -z "${SIFT_TEST_SSH_PORT:-}" ]; then
  echo "==> Starting throwaway sshd for integration tests"
  SSHD_DIR=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N "" -f "$SSHD_DIR/client_key"
  ssh-keygen -q -t ed25519 -N "" -f "$SSHD_DIR/host_key"
  cp "$SSHD_DIR/client_key.pub" "$SSHD_DIR/authorized_keys"
  PORT=$(( (RANDOM % 20000) + 20000 ))
  cat > "$SSHD_DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SSHD_DIR/host_key
PidFile $SSHD_DIR/sshd.pid
AuthorizedKeysFile $SSHD_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
EOF
  /usr/sbin/sshd -f "$SSHD_DIR/sshd_config" -E "$SSHD_DIR/sshd.log"
  for _ in $(seq 1 20); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.5
  done
  nc -z 127.0.0.1 "$PORT" || { echo "FAIL: throwaway sshd never came up"; cat "$SSHD_DIR/sshd.log"; exit 1; }
  export SIFT_TEST_SSH_PORT=$PORT SIFT_TEST_SSH_USER="$(whoami)" SIFT_TEST_SSH_KEY="$SSHD_DIR/client_key"
fi

echo "==> Running tests"
swift test

if [ "$FULL" = 1 ]; then
  echo "==> Building fixture Xcode project (simulator)"
  FIXTURE_DD=$(mktemp -d)
  xcodebuild build-for-testing \
      -project Tests/Fixtures/XCTestProjects/SiftFixtures/SiftFixtures.xcodeproj \
      -scheme FixtureTests \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$FIXTURE_DD" -quiet

  echo "==> Enumeration-discovery E2E against the fixture (space-named target + ObjC)"
  XCTESTRUN=$(ls "$FIXTURE_DD"/Build/Products/*.xctestrun)
  BIN=$(swift build --show-bin-path)/Sift
  LISTING=$("$BIN" list --xctestrun "$XCTESTRUN" 2>/dev/null)
  echo "$LISTING"
  echo "$LISTING" | grep -q "My UITests/SpaceTargetTests/testInSpaceTarget()" \
      || { echo "FAIL: space-named target missing from enumeration"; exit 1; }
  echo "$LISTING" | grep -q "ObjCTests/LegacyObjCTests/testObjCStyleAssertion()" \
      || { echo "FAIL: ObjC tests missing from enumeration"; exit 1; }
  echo "$LISTING" | grep -q "testStaticHelper" \
      && { echo "FAIL: static helper leaked into discovery"; exit 1; }

  echo "==> Process-leak sweep"
  LEAKED=$(pgrep -fl "sift-attempt:" | grep -v pgrep || true)
  [ -z "$LEAKED" ] || { echo "FAIL: leaked sift-owned processes:"; echo "$LEAKED"; exit 1; }
fi

echo "==> ci.sh: all gates green"
