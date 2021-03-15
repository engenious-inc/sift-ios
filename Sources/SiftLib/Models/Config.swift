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
    public var tests: [Test]?
    
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Config.self, from: data)
    }
    
    public init(path: String) throws {
        let json = try Data(contentsOf: URL(fileURLWithPath: path))
        try self.init(data: json)
    }

    public func getTestId(testName: String) -> Int? {
        return self.tests?.first(where: {$0.testName == testName} )?.testID
    }
    
    public mutating func injectedEnvVariables() -> Self{
        injectPathVariables(pathName: &outputDirectoryPath)
        injectPathVariables(pathName: &xctestrunPath)
        return self
    }
    
    private func injectPathVariables(pathName: inout String)  {
        let matches = pathName.regexMatches(for: "\\$\\{?[A-Z0-9_\\}?]+")
        var envVariables: [String : String] = [:]
        let shell = Run()

        for match in matches {
            let value = try? shell.run("echo \(match)").output.replacingOccurrences(of: "\n", with: "")
            if value == nil || value == "" {
                Log.error("Variable value not found for \(match)")
            }
            envVariables[match] = value
        }
        for (key, value) in envVariables {
            pathName = pathName.replacingOccurrences(of: key, with: value)
        }
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
        public var pathToCertificate: String?
        public var deploymentPath: String
        public var UDID: UDID
        public var xcodePath: String = "/Applications/Xcode.app"
        public var environmentVariables: [String: String?]?
    }
    
    public struct Test: Codable {
        public var testID: Int
        public var testName: String

        enum CodingKeys: String, CodingKey {
            case testID = "testId"
            case testName
        }
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable {
        public var simulators: [String]?
        public var devices: [String]?
    }
}
