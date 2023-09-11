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
    
    public func write(url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
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
