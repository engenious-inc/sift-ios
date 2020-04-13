# sift
SIFT

Sift - Unit and UI Tests Parallelization


## sift run --config path/config.json


config.json -  config file (JSON format):

    {
        "xctestrunPath": "path to .xctestrun, this file generate by Xcode when make a build for test",
        "outputDirectoryPath": "path where tests results will be collected",
        "rerunFailedTest": 1, // attempts for retry
        "testsBucket": 1, // number of tests which will be send on each executor at the same time
        "testsExecutionTimeout": 120, // timeout
        "setUpScriptPath": "script will execute on node before each tests bucket", // can be null
        "tearDownScriptPath": "script will execute on node after each tests bucket", // can be null
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
                        }
                "xcodePath": "/Applications/Xcode.app", // path to xcode
                "environmentVariables": null // inject env if need
            }
        ]
    }

Requirements:
	
	Xcode 11+
	brew install libssh2
	brew install coreutils (for timeout command)
