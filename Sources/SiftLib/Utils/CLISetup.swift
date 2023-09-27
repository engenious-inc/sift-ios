//
//  CLISetup.swift
//
//
//  Created by AP on 9/10/23.
//

import Foundation
import Rainbow

public enum CLISetup {
    public static func start() -> Config {
        var config = Config()
        var defaultPrivateKeyPath: String?
        var defaultPublicKeyPath: String?
        print("Welcome to interactive setup mode. This mode will help you to setup Sift.".bold)
        
        // Initial questions
        config.xctestrunPath = getInput(prompt: "Provide the path for the .xctestrun file")
        config.outputDirectoryPath = getInput(prompt: "Please provide the directory path where test results should be collected")
        config.rerunFailedTest = getInput(prompt: "How many retries should be made for failed tests?", defaultValue: 1)
        config.testsBucket = getInput(prompt: "How many tests should be in a bucket?", defaultValue: 1)
        config.testsExecutionTimeout = getInput(prompt: "What should be the test execution timeout (in seconds)?", defaultValue: 600)

        var id = 1
        while getInput(prompt: "Would you like to add an execution node? (y/n)").lowercased() == "y" {
            
            let nodeName: String = getInput(prompt: "Please provide a name for this node")
            let nodeHost: String = getInput(prompt: "Please provide the host for this node")
            let nodePort: Int = getInput(prompt: "Please provide the port for this node", defaultValue: 22)
            let nodeUsername: String = getInput(prompt: "Please provide the username for this node")
            
            var nodePrivateKeyPath: String = ""
            var nodePublicKeyPath: String = ""
            print("For SSH authentication you have to provide path to ED25519 Private/Public keys pair")
            if getInput(prompt: "Would you like to generate ED25519 keys pair? (y/n)").lowercased() == "y" {
                if let output = try? GenerateSSHKeys.generateEd25519KeysPair() {
                    nodePrivateKeyPath = output.privateKeyPath
                    nodePublicKeyPath = output.publicKeyPath
                    print("Generate keys pair:")
                    print("Private Key: \(output.privateKeyPath)")
                    print("Public Key: \(output.publicKeyPath)")
                } else {
                    print("Can't generate ED25519 keys pair")
                }
            } 
            if nodePrivateKeyPath.isEmpty || nodePublicKeyPath.isEmpty {
                nodePrivateKeyPath = getInput(prompt: "Please provide path to the private key", defaultValue: defaultPrivateKeyPath)
                nodePublicKeyPath = getInput(prompt: "Please provide path to the public key", defaultValue: defaultPublicKeyPath)
            }
            defaultPrivateKeyPath = nodePrivateKeyPath
            defaultPublicKeyPath = nodePublicKeyPath
            print("This is your Public Key:")
            print((try? String(contentsOfFile: nodePublicKeyPath)) ?? "")
            print("You have to add Public Key which you can see above into \"authorized_keys\" file on \"\(nodeName) - \(nodeHost)\" in directory \"~/.ssh\". If \"authorized_keys\" file dosen't exests then create it.")
            let nodeDeploymentPath: String = getInput(prompt: "Please provide the deployment path for this node")
            let nodeXcodePath: String = getInput(prompt: "Please provide the Xcode path for this node", defaultValue: "/Applications/Xcode.app")
            
            var udid: Config.NodeConfig.UDID = .init()
            if getInput(prompt: "Would you like to add an Device/Simulator UDID for this node? (y/n)").lowercased() == "y" {
                print("Select the option on which type of device you are going to test:")
                print("1. Simulator")
                print("2. iOS Device (iPhone or iPad)")
                print("3. MacOS")
                var optionNumber: Int = 0
                while true {
                    optionNumber = getInput(prompt: "Provide the number")
                    if optionNumber > 0 && optionNumber < 4 {
                        print("Hint:")
                        print("to list all simulators run: xcrun xctrace list")
                        print("to list all connected devices run: xcrun xctrace list devices")
                        break
                    }
                }
                
                var nodeUDIDs: [String] = []
                while true {
                    let udid: String = getInput(prompt: "Provide the UDID", defaultValue: "Done")
                    if udid == "Done" {
                        break
                    }
                    nodeUDIDs.append(udid)
                }
                
                if optionNumber == 1 {
                    udid.simulators = nodeUDIDs
                } else if optionNumber == 2 {
                    udid.devices = nodeUDIDs
                } else if optionNumber == 3 {
                    udid.mac = nodeUDIDs
                }
            }
            
            let node = Config.NodeConfig(
                id: id,
                name: nodeName,
                host: nodeHost,
                port: Int32(nodePort),
                username: nodeUsername,
                privateKey: nodePrivateKeyPath,
                publicKey: nodePublicKeyPath,
                deploymentPath: nodeDeploymentPath,
                UDID: udid,
                xcodePath: nodeXcodePath
            )
            
            config.nodes.append(node)
            id += 1
        }
        
        return config
    }
    
    private static func getInput(prompt: String, defaultValue: String? = nil) -> String {
        let defaultValueMessage = defaultValue == nil ? "" : " | default = \(defaultValue!)"
        print(prompt + defaultValueMessage, terminator: ": ")
        guard let value = readLine(), !value.isEmpty else {
            if let defaultValue = defaultValue {
                return defaultValue
            }
            print("This field is required, please enter a value".red)
            return getInput(prompt: prompt, defaultValue: defaultValue)
        }
        return value.trimmingCharacters(in: .newlines)
    }
    
    private static func getInput(prompt: String, defaultValue: Int? = nil) -> Int {
        let defaultValueString = defaultValue == nil ? nil : "\(defaultValue!)"
        let value: String = getInput(prompt: prompt, defaultValue: defaultValueString)
        guard let intValue = Int(value) else {
            print("Enter Integer value please".red)
            return getInput(prompt: prompt, defaultValue: defaultValue)
        }
        return intValue
    }
}
