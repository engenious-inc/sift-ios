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
    /// Opt back in to xcodebuild's own parallel testing inside a chunk (default: disabled —
    /// nested parallelism spawns simulator clones the scheduler cannot account for).
    public var allowXcodebuildParallelTesting: Bool?
    public var nodes: [NodeConfig]
    public var tests: [String]?

    public init(data: Data) throws {
        // Same pipeline as init(path:): substitution and validation must not
        // depend on which initializer loaded the bytes.
        let substituted = try Config.substituteEnvironmentVariables(inJSON: data)
        self = try JSONDecoder().decode(Config.self, from: substituted)
        try validate()
    }

    public init(path: String) throws {
        guard let raw = FileManager.default.contents(atPath: path) else {
            throw ConfigError(violations: ["config file not found or unreadable: \(path)"])
        }
        try self.init(data: raw)
    }

    public func write(url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // Configs can hold SSH credentials: the file is born 0600 (owner-only temp
        // file, atomically renamed) — there is never a default-permission window.
        let temporaryPath = url.path + ".tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temporaryPath, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError(violations: ["cannot write config to \(temporaryPath)"])
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: URL(fileURLWithPath: temporaryPath))
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw error
        }
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
        var seenNames = Set<String>()
        var seenEndpoints = Set<String>()
        var seenUDIDs = Set<String>()
        for node in nodes {
            let label = "node '\(node.name)'"
            validate(path: node.deploymentPath, name: "\(label) deploymentPath", into: &violations)
            validate(path: node.xcodePathRaw, name: "\(label) xcodePath", into: &violations)
            if node.host.trimmingCharacters(in: .whitespaces).isEmpty {
                violations.append("\(label): host must not be empty")
            }
            if node.port < 1 || node.port > 65535 {
                violations.append("\(label): port must be in 1...65535 (got \(node.port))")
            }
            let udidCount = (node.UDID.simulators?.count ?? 0)
                + (node.UDID.devices?.count ?? 0)
                + (node.UDID.mac?.count ?? 0)
            if udidCount == 0 {
                violations.append("\(label): at least one simulator, device, or mac UDID is required")
            }
            // Duplicate identities produce colliding remote workspaces or two
            // executors hammering one destination — reject them up front.
            if !seenNames.insert(node.name).inserted {
                violations.append("duplicate node name '\(node.name)' — node names must be unique")
            }
            let endpoint = "\(node.host):\(node.port)|\(node.deploymentPath)"
            if !seenEndpoints.insert(endpoint).inserted {
                violations.append("\(label): duplicate endpoint (host \(node.host):\(node.port), deploymentPath \(node.deploymentPath)) — merge the UDID lists into one node entry")
            }
            let allUDIDs = (node.UDID.simulators ?? []) + (node.UDID.devices ?? []) + (node.UDID.mac ?? [])
            for udid in allUDIDs where !seenUDIDs.insert("\(node.host)|\(udid.uppercased())").inserted {
                violations.append("\(label): duplicate UDID \(udid) on host \(node.host) — one executor per device")
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
