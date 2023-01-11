
## Sift - Unit and UI Tests Parallelization for native XCTest and XCUITest

### Requirements:
 - `Xcode 13`

### Install:
- `sh make.sh`

### How to Build:
- `swift build -c release`

### How to use:
https://sift.engenious.io/

### Standalone:
- `sift run --config config.json` run tests
- `sift list --config config.json` print all tests from the bundle

### With Orchestrator:
- `sift orchestartor --token 'your token' --test-plan 'name of testplan'`



### Exapmle of **config.json** file (JSON format):

```
{
 "xctestrunPath": "path to .xctestrun, this file generate by Xcode when make a build for test",
    "outputDirectoryPath": "path where tests results will be collected",
    "rerunFailedTest": 1, // attempts for retry
    "testsBucket": 1,
    "testsExecutionTimeout": 120, // timeout
    "nodes": // array of nodes (mac)
    [
        {
          "name": "Node1",
          "host": "127.0.0.1",
          "port": 22,
          "deploymentPath": "path where all necessary stuff will be stored on the node",
         "UDID": {
                        "devices": ["devices udid, can be null"],
                        "simulators": ["simulators udid, can be null"]
                    },
          "xcodePath": "/Applications/Xcode.app",
          "authorization": {
            "data": {
              "username": "username",
              "password": "password"
            }
          }
        }
    ]
}

```
