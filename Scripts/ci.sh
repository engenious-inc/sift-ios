#!/bin/bash
# Sift CI gate. Every phase merges only when this script exits 0.
#
#   ./Scripts/ci.sh          fast gate: resolve + build + unit/CLI tests
#   ./Scripts/ci.sh --full   adds a throwaway local sshd (SSH integration tests),
#                            the fixture Xcode project build, a real enumeration-
#                            discovery check, a full `sift run` of the fixture
#                            (local transport), and a SIGINT-cancellation run
#                            verifying partial reports + no leaked processes
#                            (needs an iOS simulator)
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

  echo "==> Full E2E: sift run of the fixture (local transport)"
  E2E_UDID=$(xcrun simctl list devices --json | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
best = None
for runtime in sorted(devices, reverse=True):
    if 'SimRuntime.iOS' not in runtime: continue
    for device in devices[runtime]:
        if not device.get('isAvailable'): continue
        if device['state'] == 'Booted':
            print(device['udid']); sys.exit()
        best = best or device['udid']
print(best or '')")
  [ -n "$E2E_UDID" ] || { echo "FAIL: no iOS simulator available for the E2E run"; exit 1; }
  E2E_DIR=$(mktemp -d)
  XCODE_APP=$(dirname "$(dirname "$(xcode-select -p)")")
  cat > "$E2E_DIR/config.json" <<EOF
{ "xctestrunPath": "$XCTESTRUN", "outputDirectoryPath": "$E2E_DIR/out",
  "rerunFailedTest": 0, "testsBucket": 2, "testsExecutionTimeout": 300,
  "nodes": [{ "name": "ci-local", "transport": "local", "deploymentPath": "$E2E_DIR/deploy",
              "UDID": { "simulators": ["$E2E_UDID"] }, "xcodePath": "$XCODE_APP" }] }
EOF
  "$BIN" run --config "$E2E_DIR/config.json" --timeout 900
  python3 - "$E2E_DIR/out/final/final_result.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))["summary"]
assert summary["tests"] >= 6, f"expected the full fixture suite, got {summary['tests']}"
assert summary["passed"] == summary["tests"], f"fixture tests failed: {summary}"
assert summary["unexecuted"] == 0, f"unexecuted tests in a clean run: {summary}"
print(f"    fixture run: {summary['passed']}/{summary['tests']} passed")
PY

  echo "==> Full E2E: SIGINT mid-run (exit 130, partial reports, terminal event, no orphans)"
  rm -rf "$E2E_DIR/out"
  "$BIN" run --config "$E2E_DIR/config.json" --timeout 900 \
      --events-path "$E2E_DIR/events.ndjson" >/dev/null 2>&1 &
  RUN_PID=$!
  for _ in $(seq 1 120); do
    grep -q chunkStarted "$E2E_DIR/events.ndjson" 2>/dev/null && break
    sleep 1
  done
  grep -q chunkStarted "$E2E_DIR/events.ndjson" 2>/dev/null \
      || { echo "FAIL: run never started a chunk before the SIGINT window"; kill "$RUN_PID" 2>/dev/null; exit 1; }
  kill -INT "$RUN_PID"
  SIGINT_CODE=0; wait "$RUN_PID" || SIGINT_CODE=$?
  [ "$SIGINT_CODE" = 130 ] || { echo "FAIL: SIGINT run exited $SIGINT_CODE, expected 130"; exit 1; }
  [ -f "$E2E_DIR/out/final/final_result.json" ] \
      || { echo "FAIL: cancelled run published no partial reports"; exit 1; }
  grep -q runFinished "$E2E_DIR/events.ndjson" \
      || { echo "FAIL: event stream has no terminal runFinished event"; exit 1; }

  echo "==> Process-leak sweep"
  LEAKED=$(pgrep -fl "sift-attempt:" | grep -v pgrep || true)
  [ -z "$LEAKED" ] || { echo "FAIL: leaked sift-owned processes:"; echo "$LEAKED"; exit 1; }
fi

echo "==> ci.sh: all gates green"
