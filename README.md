# Sift-iOS: Parallel XCTest Execution

## [What Is Sift?](https://sift.engenious.io/)

Sift is an open-source tool that parallelizes XCTest runs across multiple simulators and physical devices, on one machine or a whole farm of remote nodes, dramatically reducing total test time. It distributes prebuilt test bundles over SSH, runs chunks of tests via `xcodebuild test-without-building`, retries failures, merges all results into a single `.xcresult`, and emits JUnit XML and JSON reports.

**Requirements:** macOS 12+, Xcode 16 or newer on every node (Sift uses the modern `xcresulttool get test-results` API).

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
| `rerunFailedTest` | How many times a failed test is retried. |
| `testsBucket` | Number of tests handed to an executor per `xcodebuild` invocation. |
| `testsExecutionTimeout` | Wall-clock seconds allowed for one bucket; the remote `xcodebuild` is terminated (TERM→KILL) on expiry. Also injected as the per-test time allowance. |
| `setUpScriptPath` / `tearDownScriptPath` | Optional shell scripts run on the node before/after each bucket (env: `TEST_NAME`, `TEST_NAMES`, `UDID`). A nonzero setup exit returns the bucket to the queue. |
| `onlyTestConfiguration` / `skipTestConfiguration` | Test-plan configuration selection (FormatVersion 2 only). |
| `nodes[].privateKey` / `password` | Key-based (recommended) or password SSH auth. With neither, ssh-agent is used. Sift never prompts interactively. |
| `nodes[].deploymentPath` | Absolute node-side working directory. Each run uses an isolated `deploymentPath/.sift/runs/<run-id>/` and removes only that. |
| `nodes[].UDID` | Any mix of `simulators`, `devices`, and `mac` UDIDs — all run concurrently. |
| `nodes[].hostKeyVerification` | `strict` (must be in `~/.sift/known_hosts`), `acceptNew` (default, trust-on-first-use), or `off`. |
| `nodes[].arch` | Optional `arch -<value>` prefix for remote commands (`arm64`, `x86_64`). |

Values support `${ENV_VAR}` substitution; unresolved variables are an error.

### 4. Run

```bash
Sift run --config config.json            # exit 0 = all passed; 1 = failures; 124 = timeout/cancelled
Sift run --config config.json --only-testing 'Module/Class/testName()'
Sift run --config config.json --tests-path tests.txt   # newline-separated test list
Sift run --config config.json --timeout 3600           # global watchdog (exit 124 on expiry)
Sift list --config config.json           # print all tests in the bundles, no SSH needed
```

Exit codes: `0` success · `1` test failures / unexecuted tests / infrastructure failure · `64` invalid config · `124` global timeout or SIGINT/SIGTERM cancellation (partial reports are still written).

Ctrl-C cancels the run gracefully: remote `xcodebuild` processes are terminated and partial reports are generated.

## Development

```bash
swift build --build-tests && swift test
```

The package has a unit-test target (`Tests/SiftLibTests`) with fixtures recorded from real Xcode output; CI runs on every PR.
