
## Sift - Unit and UI Tests Parallelization

### Requirements:
 - `Xcode 12`

### Install:
- `sh make.sh`

### How to Build:
- `swift build -c release`

### How to use:

### With Orchestrator:
- `sift orchestrator --token 'your token' --test-plan 'name of testplan'`

### Standalone:
- `sift run --config config.json` run tests
- `sift list --config config.json` print all tests from the bundle

### Exapmle of **config.json** file (JSON format):

```
{
    "xctestrunPath": "path to .xctestrun, this file generate by Xcode when make a build for test",
    "outputDirectoryPath": "path where tests results will be collected",
    "rerunFailedTest": 1, // attempts for retry
    "testsBucket": 1, // number of tests which will be send on each executor at the same time
    "testsExecutionTimeout": 120, // timeout
    "setUpScriptPath": "script will execute on node before each tests bucket", // optional
    "tearDownScriptPath": "script will execute on node after each tests bucket", // optional
    "nodes": // array of nodes (mac)
    [
        {
            "name": "Node-1",
            "host": "172.22.22.12",
            "port": 22,
            "username": "node-1",
            "password": "password",
            "deploymentPath": "path where all necessary stuff will be stored on the node",
            "UDID": {
                        "devices": ["devices udid, can be null"],
                        "simulators": ["simulators udid, can be null"]
                    },
            "xcodePath": "/Applications/Xcode.app", // path to xcode
            "environmentVariables": ["env1": "value1"] // inject env if need, optional
            "arch": "arm64" // optional: "i386", "x86_64" or "arm64" - for Apple M1 silicon
        }
    ]
}
```
