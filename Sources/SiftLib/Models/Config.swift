import Foundation

public struct Config: Codable {
    public var id: Int?
    public var xctestrunPath: String
    public var outputDirectoryPath: String
    public var rerunFailedTest: Int
    public var testsBucket: Int
    public var testsExecutionTimeout: Int?
    public var setUpScriptPath: String?
    public var tearDownScriptPath: String?
	public var onlyTestConfiguration: String?
	public var skipTestConfiguration: String?
    public var nodes: [NodeConfig]
    public var tests: [String]?
    
    init() {
        xctestrunPath = ""
        outputDirectoryPath = ""
        rerunFailedTest = 0
        testsBucket = 0
        nodes = []
    }
    
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Config.self, from: data)
    }
    
    public init(path: String) throws {
        let json = try NSData(contentsOfFile: path) as Data
		let jsonString = json.string(encoding: .utf8)
		let parsedJsonData = jsonString?.matches(regex: "\\$\\{[a-zA-Z0-9_\\-\\.]+\\}")
			.map { String($0.dropFirst(2).dropLast()) }
			.reduce(into: jsonString ?? "") { result, element in
				if let env = ProcessInfo().environment[element] {
					result = result?.replacingOccurrences(of: "${\(element)}", with: env)
				}
			}?.data(using: .utf8)
        try self.init(data: parsedJsonData ?? json)
    }
}

extension Config {
    public struct NodeConfig: Codable {
        public var id: Int
        public var name: String
        public var host: String
        public var port: Int32
        public var username: String
        public var password: String?
        public var privateKey: String?
        public var publicKey: String?
        public var passphrase: String?
        public var deploymentPath: String
        public var UDID: UDID
		private var xcodePath: String
		public var xcodePathSafe: String { xcodePath.replacingOccurrences(of: " ", with: "\\ ") }
        public var environmentVariables: [String: String]?
		public var arch: Arch?
		
		public enum Arch: String, Codable {
			case i386
			case x86_64
			case arm64
		}
        
        init(id: Int, name: String, host: String, port: Int32, username: String, password: String? = nil, privateKey: String? = nil, publicKey: String? = nil, passphrase: String? = nil, deploymentPath: String, UDID: UDID, xcodePath: String, environmentVariables: [String : String]? = nil, arch: Arch? = nil) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.passphrase = passphrase
            self.deploymentPath = deploymentPath
            self.UDID = UDID
            self.xcodePath = xcodePath
            self.environmentVariables = environmentVariables
            self.arch = arch
        }
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable {
        public var simulators: [String]?
        public var devices: [String]?
		public var mac: [String]?
    }
}

extension Config {
    public static func cliSetup() -> Config {
        var config = Config()
        print("Welcom to interactive setup mode. This mode will help you to setup Sift.")
        
        // Initial questions
        config.xctestrunPath = getInput(prompt: "Please provide the path for the .xctestrun file")
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
            let nodePrivateKeyPath: String = getInput(prompt: "Please provide path to the private key on this node")
            let nodePublicKeyPath: String = getInput(prompt: "Please provide path to the public key on this node", defaultValue: nodePrivateKeyPath + ".pub")
            let nodeDeploymentPath: String = getInput(prompt: "Please provide the deployment path for this node")
            let nodeXcodePath: String = getInput(prompt: "Please provide the Xcode path for this node", defaultValue: "/Applications/Xcode.app")
            
            var udid: NodeConfig.UDID = .init()
            if getInput(prompt: "Would you like to add an Device/Simulator UDID for this node? (y/n)").lowercased() == "y" {
                print("Select the option on which type of device you are going to test:")
                print("1. Simulator")
                print("2. iOS Device (iPhone or iPad)")
                print("3. MacOS")
                var optionNumber: Int = 0
                while true {
                    optionNumber = getInput(prompt: "Provide the number")
                    if optionNumber > 0 && optionNumber < 4 {
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
            
            let node = NodeConfig(
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
        let defaultValueMessage = defaultValue == nil ? "" : " default = \(defaultValue!)"
        print(prompt + defaultValueMessage, terminator: ": ")
        guard let value = readLine(), !value.isEmpty else {
            if let defaultValue = defaultValue {
                return defaultValue
            }
            print("This field is required, please enter a value")
            return getInput(prompt: prompt, defaultValue: defaultValue)
        }
        return value
    }
    
    private static func getInput(prompt: String, defaultValue: Int? = nil) -> Int {
        let defaultValueString = defaultValue == nil ? nil : "\(defaultValue!)"
        let value: String = getInput(prompt: prompt, defaultValue: defaultValueString)
        guard let intValue = Int(value) else {
            print("Enter Integer value please")
            return getInput(prompt: prompt, defaultValue: defaultValue)
        }
        return intValue
    }
}
