# Sift-iOS: Parallel XCTest Execution

## [What Is Sift?](https://sift.engenious.io/)

Sift is an open-source tool that parallelizes XCTest runs across multiple simulators and physical devices, on one machine or a whole farm of remote nodes, dramatically reducing total test time. It distributes prebuilt test bundles over SSH, runs chunks of tests via `xcodebuild test-without-building`, retries failures, merges all results into a single `.xcresult`, and emits JUnit XML and JSON reports.

**Requirements:** macOS 14.5+ and Xcode 16 or newer on the controller and every node (Sift uses the modern `xcresulttool get test-results` and `-enumerate-tests` APIs). Remote nodes are reached over SSH (`Remote Login` enabled); the local machine needs no sshd at all — give its node entry `"transport": "local"` (this also runs macOS UI tests inside your login session, where `testmanagerd` is reachable). XCTest (Swift and Objective-C) and Swift Testing (`@Test`, suites and top-level functions) are both supported. One run's executors must match the artifact's platform (all simulators, or all devices, or all macOS — mixed runs are rejected).

## Quick Start

### 1. Build Sift

```bash
git clone https://github.com/engenious-inc/sift-ios
cd sift-ios
swift build -c release
# binary at .build/release/Sift
```

### 2. Build your tests

Build for testing once (locally or on CI):

```bash
xcodebuild build-for-testing \
  -project YourApp.xcodeproj \
  -scheme YourUITests \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData
```

This produces a `.xctestrun` file in `DerivedData/Build/Products/`.

### 3. Write a config

```jsonc
{
    "xctestrunPath": "/absolute/path/to/YourUITests.xctestrun",
    "outputDirectoryPath": "/absolute/path/to/results",
    "rerunFailedTest": 1,
    "testsBucket": 4,
    "testsExecutionTimeout": 600,
    "nodes": [
        {
            "name": "node-1",
            "host": "192.168.1.10",
            "port": 22,
            "username": "ci",
            "privateKey": "/Users/ci/.ssh/id_ed25519",
            "deploymentPath": "/Users/ci/sift-workdir",
            "xcodePath": "/Applications/Xcode.app",
            "UDID": {
                "simulators": ["SIMULATOR-UDID-1", "SIMULATOR-UDID-2"],
                "devices": [],
                "mac": []
            },
            "environmentVariables": { "MY_ENV": "value" },
            "hostKeyVerification": "acceptNew"
        }
    ]
}
```

Config reference:

| Field | Description |
|---|---|
| `xctestrunPath` | Absolute path to the `.xctestrun` produced by `build-for-testing`. FormatVersion 1 and 2 are supported. |
| `outputDirectoryPath` | Absolute path where `final/` (merged `.xcresult`, `final_result.xml` JUnit, `final_result.json`, `final_result.txt`) is written. |
| `rerunFailedTest` | How many times a failed test is retried (default 0). |
| `testsBucket` | Number of tests handed to an executor per `xcodebuild` invocation (required for `run`). |
| `testsExecutionTimeout` | Wall-clock seconds allowed for one bucket; the remote `xcodebuild` is terminated (TERM→KILL) on expiry. Also injected as the per-test time allowance. |
| `setUpScriptPath` / `tearDownScriptPath` | Optional scripts run on the node before/after each bucket. Uploaded as 0700 files and executed directly — the shebang is honored. Env: `TEST_NAME`, `TEST_MANIFEST` (path to a newline-delimited test list), `UDID`, plus your `environmentVariables` (`TEST_NAMES` is deprecated, kept one release). A nonzero setup exit returns the bucket to the queue; a nonzero teardown is reported as a health event. |
| `onlyTestConfiguration` / `skipTestConfiguration` | Test-plan configuration selection (FormatVersion 2 only): `selected = enabled ∩ (only ?? all) ∖ {skip}`. Unknown names and empty selections are errors. With several selected configurations, every test runs once per configuration and report names are qualified (`test() [Config B]`). |
| `nodes[].privateKey` / `password` | Exactly ONE of key-based (recommended) or password SSH auth may be set — both is a config error; with neither, ssh-agent is used. A missing `.pub` sidecar is fine (derived from the private key). Sift never prompts interactively. |
| `nodes[].deploymentPath` | Absolute node-side working directory. Each run uses an isolated, 0700 `deploymentPath/.sift/runs/<run-id>/<node>/` and removes only that. Duplicate host+deploymentPath node entries are rejected. |
| `allowXcodebuildParallelTesting` | Opt back in to xcodebuild's own parallel testing inside a chunk (default: disabled — Sift passes `-parallel-testing-enabled NO`). |
| `nodes[].transport` | `"ssh"` (default) or `"local"` (this machine: no host/credentials, login-session context). |
| `nodes[].UDID` | `simulators`, `devices`, or `mac` UDIDs matching the artifact's platform — all run concurrently. |
| `nodes[].provisionSimulators` | `{"deviceType": "iPhone 17", "runtime": "iOS 26.0"?, "count": N, "deleteAfterRun": true?}` — Sift creates N owned clones for the run (the only simulators it will ever erase) and deletes them afterwards. |
| `nodes[].hostKeyVerification` | `strict` (must be in `~/.sift/known_hosts`), `acceptNew` (default, trust-on-first-use), or `off`. |
| `nodes[].arch` | Optional `arch -<value>` prefix for remote commands (`arm64`, `x86_64`). |

Values support `${ENV_VAR}` substitution; unresolved or unterminated placeholders are an
error, and `$${NAME}` produces the literal text `${NAME}`.

### 4. Run

```bash
Sift run --config config.json            # exit 0 = all passed; 1 = failures; 124 = timeout/cancelled
Sift run --config config.json --only-testing 'Bundle/Class/testName()'
Sift run --config config.json --only-testing 'Bundle/Class'        # whole class
Sift run --config config.json --only-testing 'Bundle'              # whole bundle
Sift run --config config.json --tests-path tests.txt   # newline-separated test list
Sift run --config config.json --timeout 3600           # global watchdog (exit 124 on expiry)
Sift list --config config.json           # print all tests in the bundles, no SSH needed
Sift list --xctestrun path/to/T.xctestrun               # list without any config at all
Sift doctor --config config.json         # preflight: tooling, artifact, output, every node/executor
Sift run --config config.json --events-path run.ndjson  # machine-readable event stream (v1)
```

On a TTY, `run` shows a live progress line (done/pending/in-flight counts, failures,
active chunks, elapsed time); off a TTY the per-test result lines serve as the
line-oriented progress stream. `--events-path`/`--events-stdout` emit an NDJSON
stream (`runStarted`, `chunkStarted`, `testFinished`, `chunkFinished`, `runFinished`;
schema v1) for CI dashboards — `--events-stdout` quiets human stdout output so the
stream stays machine-parsable, and `runFinished` (with a `status` field) is emitted
only after `final/` is published (an error emits `status: "error"` instead). Runs also persist per-test durations to `outputDirectoryPath/.sift/
timings.json` and schedule longest-first on the next run, shrinking the final
buckets so no executor idles behind a ragged tail.

`--tests-path` and `--only-testing` together are an error unless you pass
`--combine-test-selectors` (then their union runs). The config `tests` array is
deprecated (a warning is printed) and used only when neither CLI selector is given.
`sift list` never needs nodes or credentials — a config without them, or just
`--xctestrun`, is enough; repeatable `--only-test-configuration` /
`--skip-test-configuration` flags select configurations for listing.

Test identifiers use the `.xctest` **bundle name** as their first component (the same
namespace `xcodebuild -only-testing:` uses) — for a target named "My UITests" that is
`My UITests/LoginTests/testLogin()`. A trailing `()` always selects a method; a
selector WITHOUT it matches a class *or* a paren-less method against the discovered
tests (so `Bundle/someTopLevelTest` reaches a suite-less Swift Testing function). A
selector that matches nothing is an error with close-match suggestions, never a
silently scheduled phantom test.

### Test discovery

Discovery uses `xcodebuild -enumerate-tests` (Xcode 16+) by default: it sees
Objective-C and Swift tests alike, respects test-plan enablement, and never invents
phantom tests. Enumerating a simulator-platform artifact needs an **available local
iOS simulator** on the controller machine (it may be shut down; Sift picks a booted
one first). Device-platform artifacts need a connected device for enumeration — or
use the transitional `--discovery symbols` backend (Swift-only `nm` scan), which is
kept for one release and then removed.

Sift passes `-parallel-testing-enabled NO` to each chunk so xcodebuild cannot spawn
untracked simulator clones behind the scheduler's back; set
`"allowXcodebuildParallelTesting": true` in the config to opt back in deliberately.
A run whose executors do not match the artifact's platform (e.g. a simulator-built
xctestrun with device UDIDs) is rejected up front with every mismatch listed.

Exit codes: `0` all selected tests passed (an infrastructure failure fully compensated
by other executors still exits 0, with health events in the summary and JSON report) ·
`1` test failures / unexecuted tests · `64` invalid configuration (bad config shape,
missing controller-side files, conflicting selectors) · `124` global `--timeout`
expiry · `130` SIGINT (Ctrl-C) · `143` SIGTERM. Partial reports are written for 124/130/143.

Ctrl-C cancels gracefully: remote `xcodebuild` gets a full TERM grace period (results
that finalize are salvaged), executors are never blamed or reset, and partial reports
plus the merged `.xcresult` are still published.

Errors and warnings go to **stderr**; stdout carries results and progress only.
Reports are staged privately and published to `final/` in one atomic rename — a failed
or killed run leaves the previous `final/` untouched, and an advisory lock keeps two
runs from sharing one `outputDirectoryPath` (the error names the owning run).
USER-PROVIDED simulators are never erased: an unbooted simulator is booted (and shut
back down when the run ends), and recovery is shutdown+boot only. The one exception
is Sift-OWNED provisioned clones (`provisionSimulators`), which are erased on
recovery for a maximally clean retry and deleted when the run ends.

## Development

```bash
swift build --build-tests && swift test
```

The package has a unit-test target (`Tests/SiftLibTests`) with fixtures recorded from real Xcode output; CI runs on every PR.
