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
    public var nodes: [NodeConfig]
    public var tests: [Test]?
    
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Config.self, from: data)
    }
    
    public init(path: String) throws {
        let json = try NSData(contentsOfFile: path) as Data
        try self.init(data: json)
    }
    
    public func getTests() -> [String] {
        return tests!.map { $0.testName }
    }
}

extension Config {
    public struct NodeConfig: Codable {
        public var id: Int
        public var name: String
        public var host: String
        public var port: Int32
        public var username: String
        public var pathToCertificate: String? // match old api
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

public struct Test: Codable {
    public var testID: Int
    public var testName: String

    enum CodingKeys: String, CodingKey {
        case testID = "testId"
        case testName
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable {
        public var simulators: [String]?
        public var devices: [String]?
		public var mac: [String]?
    }
}
