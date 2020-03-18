import Foundation

public struct Config: Codable {
    public var xctestrunPath: String
    public var outputDirectoryPath: String
    public var rerunFailedTest: Int
    public var testsBucket: Int
    public var testsExecutionTimeout: Int
    public var setUpScriptPath: String?
    public var tearDownScriptPath: String?
    public var nodes: [NodeConfig]
    
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
        public let name: String
        public let host: String
        public let port: Int32
        public let username: String
        public let password: String
        public let deploymentPath: String
        public let UDID: UDID
        public var xcodePath: String = "/Applications/Xcode.app"
        public let environmentVariables: [String: String]?
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable {
        public var simulators: [String]?
        public var devices: [String]?
    }
}
