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
    
    public func getTests() -> [String] {
        return tests!.map { $0.testName }
    }
    
    public func getTestId(testName: String) -> Int? {
        return self.tests?.first(where: {$0.testName == testName} )?.testID
    }
}

extension Config {
    public struct NodeConfig: Codable {
        public var id: Int?
        public var name: String
        public var host: String
        public var port: Int32
        public var deploymentPath: String
        public var UDID: UDID
        public var xcodePath: String
        public var authorization: Authorization
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

// MARK: - Authorization
extension Config.NodeConfig {
    public struct Authorization: Codable {
        public var type: String?
        public var data: DataClass
    }
}

// MARK: - DataClass
extension Config.NodeConfig.Authorization {
    public struct DataClass: Codable {
        public var username: String
        public var password: String?
        public var privateKey: String?
        public var publicKey: String?
        public var passphrase: String?
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
