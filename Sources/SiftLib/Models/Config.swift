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

    /// What the config is being used for: `list` needs only discovery inputs and
    /// skips node validation entirely.
    public enum Role: Sendable {
        case run
        case list
    }

    public init(data: Data, role: Role = .run) throws {
        // Same pipeline as init(path:): substitution and validation must not
        // depend on which initializer loaded the bytes.
        let substituted = try Config.substituteEnvironmentVariables(inJSON: data)
        self = try JSONDecoder().decode(Config.self, from: substituted)
        try validate(role: role)
    }

    public init(path: String, role: Role = .run) throws {
        guard let raw = FileManager.default.contents(atPath: path) else {
            throw ConfigError(violations: ["config file not found or unreadable: \(path)"])
        }
        try self.init(data: raw, role: role)
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
    /// Contract: `$${NAME}` produces the literal text `${NAME}`; every other unmatched
    /// or unterminated `${` — and every unresolved variable — is an error, never a
    /// silent literal.
    static func substituteEnvironmentVariables(inJSON data: Data) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError(violations: ["config is not valid JSON: \(error.localizedDescription)"])
        }
        var problems: [String] = []
        let substituted = substitute(object, environment: ProcessInfo.processInfo.environment, problems: &problems)
        guard problems.isEmpty else {
            throw ConfigError(violations: problems)
        }
        return try JSONSerialization.data(withJSONObject: substituted)
    }

    private static func substitute(_ value: Any, environment: [String: String], problems: inout [String]) -> Any {
        switch value {
        case let string as String:
            return substitute(string, environment: environment, problems: &problems)
        case let array as [Any]:
            return array.map { substitute($0, environment: environment, problems: &problems) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { substitute($0, environment: environment, problems: &problems) }
        default:
            return value
        }
    }

    private static func substitute(_ string: String, environment: [String: String], problems: inout [String]) -> String {
        guard string.contains("${") else { return string }
        var result = ""
        var remainder = Substring(string)
        while let start = remainder.range(of: "${") {
            let escaped = remainder[..<start.lowerBound].hasSuffix("$") // "$${" → literal "${"
            let prefixEnd = escaped ? remainder.index(before: start.lowerBound) : start.lowerBound
            result += remainder[..<prefixEnd]
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.firstIndex(of: "}") else {
                problems.append("unterminated '${' in config value '\(string)' — close it with '}' or escape it as '$${'")
                return result + remainder[start.lowerBound...]
            }
            let name = String(afterStart[..<end])
            if escaped {
                result += "${\(name)}"
            } else if let value = environment[name] {
                result += value
            } else {
                problems.append("unresolved environment variable ${\(name)} in config — export it, remove the placeholder, or escape it as '$${\(name)}'")
            }
            remainder = afterStart[afterStart.index(after: end)...]
        }
        result += remainder
        return result
    }

    // MARK: - Validation

    public func validate() throws {
        try validate(role: .run)
    }

    public func validate(role: Role) throws {
        var violations: [String] = []

        validate(path: xctestrunPath, name: "xctestrunPath", into: &violations)
        if let only = onlyTestConfiguration, let skip = skipTestConfiguration, only == skip {
            violations.append("onlyTestConfiguration and skipTestConfiguration are both '\(only)' — that selects nothing")
        }

        if role == .list {
            // Listing needs only the discovery inputs — nodes, credentials, and
            // output paths are irrelevant and must not be demanded.
            guard violations.isEmpty else { throw ConfigError(violations: violations) }
            return
        }

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
            } else if node.host != node.host.trimmingCharacters(in: .whitespaces) || node.host.contains(" ") {
                violations.append("\(label): host contains whitespace ('\(node.host)')")
            }
            if node.username.trimmingCharacters(in: .whitespaces).isEmpty {
                violations.append("\(label): username must not be empty")
            }
            if node.name.trimmingCharacters(in: .whitespaces).isEmpty {
                violations.append("node with host \(node.host): name must not be empty")
            }
            // Exactly one authentication method may be set: password OR privateKey.
            // Both is ambiguous (which wins?); neither means ssh-agent.
            if node.password != nil && node.privateKey != nil {
                violations.append("\(label): both password and privateKey are set — choose exactly one (ssh-agent is used when neither is set)")
            }
            // Env-var NAMES are interpolated into a remote shell prologue — a name
            // like 'FOO; rm -rf ~' would inject. Values are always shell-quoted.
            for key in (node.environmentVariables ?? [:]).keys where !Config.isValidEnvironmentName(key) {
                violations.append("\(label): invalid environment variable name '\(key)' (allowed: [A-Za-z_][A-Za-z0-9_]*)")
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

    static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let body = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard head.contains(first), name.allSatisfy({ $0.isASCII }) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy { body.contains($0) }
    }

    private func validate(path: String, name: String, into violations: inout [String]) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            violations.append("\(name) must not be empty")
            return
        }
        // The VALIDATED string must be the EXECUTED string: a path that only passes
        // after trimming would run as a different (relative!) path later.
        if trimmed != path {
            violations.append("\(name) has leading/trailing whitespace ('\(path)')")
            return
        }
        if !path.hasPrefix("/") {
            violations.append("\(name) must be an absolute path (got '\(path)')")
            return
        }
        // Resolve symlinks so a link to / or $HOME cannot smuggle a destructive target
        // past the checks.
        let standardized = (path as NSString).standardizingPath
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        for candidate in [standardized, resolved] {
            if candidate == "/" {
                violations.append("\(name) must not be the filesystem root")
                return
            }
            if candidate == NSHomeDirectory() {
                violations.append("\(name) must not be the home directory itself (got '\(path)')")
                return
            }
        }
    }

    /// Existence/readability preflight for controller-side files. Separate from the
    /// shape validation so the CLI can map these to the configuration exit code (64)
    /// instead of failing mid-run.
    public func validateRuntimeFiles(role: Role = .run) throws {
        var violations: [String] = []
        let fm = FileManager.default
        if !fm.isReadableFile(atPath: xctestrunPath) {
            violations.append("xctestrunPath does not exist or is unreadable: \(xctestrunPath)")
        }
        if role == .run {
            for (label, path) in [("setUpScriptPath", setUpScriptPath), ("tearDownScriptPath", tearDownScriptPath)] {
                if let path, !fm.isReadableFile(atPath: path) {
                    violations.append("\(label) does not exist or is unreadable: \(path)")
                }
            }
            for node in nodes {
                if let key = node.privateKey, !fm.isReadableFile(atPath: (key as NSString).expandingTildeInPath) {
                    violations.append("node '\(node.name)': privateKey does not exist or is unreadable: \(key)")
                }
            }
        }
        if !violations.isEmpty {
            throw ConfigError(violations: violations)
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
