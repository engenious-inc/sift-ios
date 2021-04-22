import Foundation

public struct Config: Codable {
    public var id: Int?
    public var xctestrunPath: String
    public var outputDirectoryPath: String
    public var rerunFailedTest: Int
    public var testsBucket: Int
    public var testsExecutionTimeout: Int
    public var setUpScriptPath: String?
    public var tearDownScriptPath: String?
    public var nodes: [NodeConfig]
    public var tests: [String]?
    
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Config.self, from: data)
    }
    
    public init(path: String) throws {
        let json = try Data(contentsOf: URL(fileURLWithPath: path))
        try self.init(data: json)
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
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable {
        public var simulators: [String]?
        public var devices: [String]?
		public var mac: [String]?
    }
}
