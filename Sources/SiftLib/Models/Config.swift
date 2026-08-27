import Foundation

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let violations: [String]
    public var description: String {
        "Invalid config:\n" + violations.map { "  - \($0)" }.joined(separator: "\n")
    }
}

public struct Config: Codable, Sendable {
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

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Config.self, from: data)
        try validate()
    }

    public init(path: String) throws {
        guard let raw = FileManager.default.contents(atPath: path) else {
            throw ConfigError(violations: ["config file not found or unreadable: \(path)"])
        }
        let substituted = try Config.substituteEnvironmentVariables(inJSON: raw)
        self = try JSONDecoder().decode(Config.self, from: substituted)
        try validate()
    }

    public func write(url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        // Configs can hold SSH credentials — never leave them world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Environment variable substitution

    /// Substitutes ${VAR} placeholders inside JSON *string values* (never keys or structure),
    /// so a value containing quotes or newlines can never corrupt the document.
    /// Unresolved placeholders are an error rather than a silent literal.
    static func substituteEnvironmentVariables(inJSON data: Data) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError(violations: ["config is not valid JSON: \(error.localizedDescription)"])
        }
        var unresolved: [String] = []
        let substituted = substitute(object, environment: ProcessInfo.processInfo.environment, unresolved: &unresolved)
        guard unresolved.isEmpty else {
            throw ConfigError(violations: unresolved.map {
                "unresolved environment variable ${\($0)} in config — export it or remove the placeholder"
            })
        }
        return try JSONSerialization.data(withJSONObject: substituted)
    }

    private static func substitute(_ value: Any, environment: [String: String], unresolved: inout [String]) -> Any {
        switch value {
        case let string as String:
            return substitute(string, environment: environment, unresolved: &unresolved)
        case let array as [Any]:
            return array.map { substitute($0, environment: environment, unresolved: &unresolved) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { substitute($0, environment: environment, unresolved: &unresolved) }
        default:
            return value
        }
    }

    private static func substitute(_ string: String, environment: [String: String], unresolved: inout [String]) -> String {
        guard string.contains("${") else { return string }
        var result = ""
        var remainder = Substring(string)
        while let start = remainder.range(of: "${") {
            result += remainder[..<start.lowerBound]
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.firstIndex(of: "}") else {
                result += remainder[start.lowerBound...]
                return result
            }
            let name = String(afterStart[..<end])
            if let value = environment[name] {
                result += value
            } else {
                unresolved.append(name)
            }
            remainder = afterStart[afterStart.index(after: end)...]
        }
        result += remainder
        return result
    }

    // MARK: - Validation

    public func validate() throws {
        var violations: [String] = []

        validate(path: xctestrunPath, name: "xctestrunPath", into: &violations)
        validate(path: outputDirectoryPath, name: "outputDirectoryPath", into: &violations)
        if testsBucket < 1 {
            violations.append("testsBucket must be >= 1 (got \(testsBucket))")
        }
        if rerunFailedTest < 0 {
            violations.append("rerunFailedTest must be >= 0 (got \(rerunFailedTest))")
        }
        if let timeout = testsExecutionTimeout, timeout < 1 {
            violations.append("testsExecutionTimeout must be >= 1 (got \(timeout))")
        }
        if nodes.isEmpty {
            violations.append("at least one node is required")
        }
        for node in nodes {
            let label = "node '\(node.name)'"
            validate(path: node.deploymentPath, name: "\(label) deploymentPath", into: &violations)
            validate(path: node.xcodePathRaw, name: "\(label) xcodePath", into: &violations)
            if node.host.trimmingCharacters(in: .whitespaces).isEmpty {
                violations.append("\(label): host must not be empty")
            }
            if node.port < 1 {
                violations.append("\(label): port must be in 1...65535 (got \(node.port))")
            }
            let udidCount = (node.UDID.simulators?.count ?? 0)
                + (node.UDID.devices?.count ?? 0)
                + (node.UDID.mac?.count ?? 0)
            if udidCount == 0 {
                violations.append("\(label): at least one simulator, device, or mac UDID is required")
            }
        }

        if !violations.isEmpty {
            throw ConfigError(violations: violations)
        }
    }

    private func validate(path: String, name: String, into violations: inout [String]) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            violations.append("\(name) must not be empty")
            return
        }
        if !trimmed.hasPrefix("/") {
            violations.append("\(name) must be an absolute path (got '\(path)')")
            return
        }
        let standardized = (trimmed as NSString).standardizingPath
        if standardized == "/" {
            violations.append("\(name) must not be the filesystem root")
        }
        if standardized == NSHomeDirectory() {
            violations.append("\(name) must not be the home directory itself (got '\(path)')")
        }
    }
}

extension Config {
    public struct NodeConfig: Codable, Sendable {
        public var id: Int?
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
        public var environmentVariables: [String: String]?
        public var arch: Arch?
        /// Host key verification policy: "strict" (must be known), "acceptNew" (trust on first
        /// use, recorded in ~/.sift/known_hosts), or "off". Default: acceptNew.
        public var hostKeyVerification: HostKeyVerification?

        var xcodePathRaw: String { xcodePath }
        /// Shell-safe quoted Xcode.app path for remote command interpolation.
        public var xcodePathSafe: String { xcodePath.shellQuoted }
        /// Unquoted DEVELOPER_DIR path.
        public var developerDirPath: String { xcodePath + "/Contents/Developer" }

        public enum Arch: String, Codable, Sendable {
            case i386
            case x86_64
            case arm64
        }

        public enum HostKeyVerification: String, Codable, Sendable {
            case strict
            case acceptNew
            case off
        }
    }
}

extension Config.NodeConfig {
    public struct UDID: Codable, Sendable {
        public var simulators: [String]?
        public var devices: [String]?
        public var mac: [String]?
    }
}
