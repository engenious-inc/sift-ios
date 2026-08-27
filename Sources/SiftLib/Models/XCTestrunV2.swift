import Foundation

/// FormatVersion 2 xctestrun (Xcode 11+ test-plan format).
///
/// Queries are answered from an immutable typed snapshot taken at parse time.
/// Mutations (environment injection, timeouts) are recorded as values and applied
/// to the ORIGINAL property-list tree in `data()`, so every key Sift does not
/// model survives the round trip to the nodes unchanged.
public struct XCTestRunV2: XCTestRun {

    struct Target: Sendable {
        var blueprintName: String?
        var productModuleName: String
        var testBundlePath: String
        var testHostPath: String
        var isEnabled: Bool
        var dependentProductPaths: [String]
        var onlyTestIdentifiers: [String]
        var skipTestIdentifiers: [String]
        var testingEnvironmentVariables: [String: String]

        var targetKey: String { blueprintName ?? productModuleName }
        var bundleName: String { TestBundleDescriptor.bundleName(fromBundlePath: testBundlePath) }
    }

    struct Configuration: Sendable {
        var name: String?
        var isEnabled: Bool
        var targets: [Target]

        var enabledTargets: [Target] { targets.filter(\.isEnabled) }
    }

    public let xctestrunFileName: String
    public let xctestrunPath: String
    public let testRootPath: String

    private let rawData: Data
    private let configurations: [Configuration]

    private var injectedEnvironment: [String: String] = [:]
    private var injectedTimeout: Int?

    init(path: String, rawData: Data, root: [String: Any]) throws {
        self.rawData = rawData
        self.xctestrunPath = path
        let pathComponents = path.components(separatedBy: "/")
        self.xctestrunFileName = pathComponents.last ?? path
        self.testRootPath = pathComponents.dropLast().joined(separator: "/")

        guard let rawConfigurations = root["TestConfigurations"] as? [[String: Any]] else {
            throw XCTestRunError("xctestrun V2 has no TestConfigurations array: \(path)")
        }
        self.configurations = try rawConfigurations.map { rawConfiguration in
            guard let rawTargets = rawConfiguration["TestTargets"] as? [[String: Any]] else {
                throw XCTestRunError("xctestrun V2 configuration has no TestTargets array: \(path)")
            }
            let targets = try rawTargets.map { rawTarget -> Target in
                guard let productModuleName = rawTarget["ProductModuleName"] as? String,
                      let testBundlePath = rawTarget["TestBundlePath"] as? String,
                      let testHostPath = rawTarget["TestHostPath"] as? String else {
                    throw XCTestRunError("xctestrun V2 target is missing ProductModuleName/TestBundlePath/TestHostPath: \(path)")
                }
                return Target(
                    blueprintName: rawTarget["BlueprintName"] as? String,
                    productModuleName: productModuleName,
                    testBundlePath: testBundlePath,
                    testHostPath: testHostPath,
                    isEnabled: rawTarget["IsEnabled"] as? Bool ?? true,
                    dependentProductPaths: rawTarget["DependentProductPaths"] as? [String] ?? [],
                    onlyTestIdentifiers: rawTarget["OnlyTestIdentifiers"] as? [String] ?? [],
                    skipTestIdentifiers: rawTarget["SkipTestIdentifiers"] as? [String] ?? [],
                    testingEnvironmentVariables: rawTarget["TestingEnvironmentVariables"] as? [String: String] ?? [:]
                )
            }
            return Configuration(
                name: rawConfiguration["Name"] as? String,
                isEnabled: rawConfiguration["IsEnabled"] as? Bool ?? true,
                targets: targets
            )
        }
        guard !configurations.isEmpty else {
            throw XCTestRunError("xctestrun V2 contains no test configurations: \(path)")
        }
    }

    // MARK: - Configuration selection

    /// Configurations that are enabled in the file.
    private var enabledConfigurations: [Configuration] { configurations.filter(\.isEnabled) }

    public func validate(configurationName: String?) throws {
        guard let configurationName else {
            // With several enabled configurations, xcodebuild would run all of them while
            // Sift schedules only the first — later configurations' failures would
            // silently overwrite scheduled verdicts. Refuse the ambiguity.
            if enabledConfigurations.count > 1 {
                let known = enabledConfigurations.compactMap(\.name).joined(separator: "', '")
                throw XCTestRunError(
                    "\(xctestrunFileName) contains \(enabledConfigurations.count) enabled test configurations ('\(known)') — " +
                    "select one with onlyTestConfiguration in the config"
                )
            }
            guard !enabledConfigurations.isEmpty else {
                throw XCTestRunError("\(xctestrunFileName) has no enabled test configurations")
            }
            return
        }
        guard let configuration = configurations.first(where: { $0.name == configurationName }) else {
            let known = configurations.compactMap(\.name).joined(separator: "', '")
            throw XCTestRunError(
                "test configuration '\(configurationName)' not found in \(xctestrunFileName); available: '\(known)'"
            )
        }
        guard configuration.isEnabled else {
            throw XCTestRunError("test configuration '\(configurationName)' is disabled in \(xctestrunFileName)")
        }
    }

    private func selectedConfiguration(_ name: String?) -> Configuration? {
        guard let name else { return enabledConfigurations.first }
        return enabledConfigurations.first { $0.name == name }
    }

    public func platform() throws -> TestPlatform {
        guard let target = (selectedConfiguration(nil) ?? configurations.first)?.targets.first else {
            throw XCTestRunError("xctestrun V2 contains no test targets: \(xctestrunPath)")
        }
        guard let platform = TestPlatform.derive(
            testHostPath: target.testHostPath,
            dyldPaths: dyldPaths(of: target.testingEnvironmentVariables)
        ) else {
            throw XCTestRunError(
                "cannot derive the target platform of \(xctestrunFileName) — " +
                "unrecognized TestHostPath '\(target.testHostPath)'"
            )
        }
        return platform
    }

    public func testBundles(config: String?) -> [TestBundleDescriptor] {
        guard let configuration = selectedConfiguration(config) else { return [] }
        return configuration.enabledTargets.map { target in
            TestBundleDescriptor(
                targetKey: target.targetKey,
                productModuleName: target.productModuleName,
                bundleName: target.bundleName,
                executablePath: executablePath(of: target)
            )
        }
    }

    public func dependentProductPaths(config: String?) -> [String] {
        guard let configuration = selectedConfiguration(config) else { return [] }
        return configuration.enabledTargets
            .flatMap(\.dependentProductPaths)
            .map { $0.replacingOccurrences(of: "__TESTROOT__", with: testRootPath) }
    }

    public func onlyTestIdentifiers(config: String?) -> [String: [String]] {
        guard let configuration = selectedConfiguration(config) else { return [:] }
        return configuration.enabledTargets.reduce(into: [:]) { result, target in
            if !target.onlyTestIdentifiers.isEmpty {
                result[target.bundleName] = target.onlyTestIdentifiers
            }
        }
    }

    public func skipTestIdentifiers(config: String?) -> [String: [String]] {
        guard let configuration = selectedConfiguration(config) else { return [:] }
        return configuration.enabledTargets.reduce(into: [:]) { result, target in
            if !target.skipTestIdentifiers.isEmpty {
                result[target.bundleName] = target.skipTestIdentifiers
            }
        }
    }

    private func dyldPaths(of environment: [String: String]) -> String {
        [
            environment["DYLD_FALLBACK_LIBRARY_PATH"],
            environment["DYLD_LIBRARY_PATH"],
            environment["DYLD_FALLBACK_FRAMEWORK_PATH"],
            environment["DYLD_FRAMEWORK_PATH"],
        ].compactMap { $0 }.joined(separator: ":")
    }

    /// Path to the test bundle's executable, used by `nm` for symbol discovery.
    private func executablePath(of target: Target) -> String {
        let bundlePath = target.testBundlePath
            .replacingOccurrences(of: "__TESTHOST__", with: target.testHostPath)
            .replacingOccurrences(of: "__TESTROOT__", with: testRootPath)
        // Bundle executable name = bundle basename minus its extension only —
        // never split on the first dot ("My.App.xctest" → "My.App").
        let basename = bundlePath.components(separatedBy: "/").last ?? target.productModuleName
        let executableName = (basename as NSString).deletingPathExtension

        if dyldPaths(of: target.testingEnvironmentVariables).contains("MacOSX.platform") {
            return "\(bundlePath)/Contents/MacOS/\(executableName)"
        }
        return "\(bundlePath)/\(executableName)"
    }

    // MARK: - Mutations

    public mutating func addEnvironmentVariables(_ values: [String: String]?) {
        guard let values, !values.isEmpty else { return }
        injectedEnvironment.merge(values) { _, new in new }
    }

    public mutating func add(timeout: Int) {
        injectedTimeout = timeout
    }

    // MARK: - Serialization

    public func data() throws -> Data {
        var root = try PlistTree.parse(rawData)
        guard var rawConfigurations = root["TestConfigurations"] as? [[String: Any]] else {
            throw XCTestRunError("xctestrun V2 lost its TestConfigurations during reserialization")
        }
        for configurationIndex in rawConfigurations.indices {
            guard var rawTargets = rawConfigurations[configurationIndex]["TestTargets"] as? [[String: Any]] else { continue }
            for targetIndex in rawTargets.indices {
                try PlistTree.merge(environment: injectedEnvironment, intoKey: "EnvironmentVariables", of: &rawTargets[targetIndex])
                if let timeout = injectedTimeout {
                    rawTargets[targetIndex]["TestTimeoutsEnabled"] = true
                    rawTargets[targetIndex]["DefaultTestExecutionTimeAllowance"] = timeout
                    rawTargets[targetIndex]["MaximumTestExecutionTimeAllowance"] = timeout
                }
            }
            rawConfigurations[configurationIndex]["TestTargets"] = rawTargets
        }
        root["TestConfigurations"] = rawConfigurations
        return try PlistTree.serialize(root)
    }
}

enum PlistTree {
    static func parse(_ data: Data) throws -> [String: Any] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XCTestRunError("property list root is not a dictionary")
        }
        return root
    }

    static func serialize(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// Merges injected variables into the dictionary at `key`, creating it when absent.
    /// An existing dictionary is preserved as `[String: Any]` — only the injected keys are
    /// overwritten, and a non-dictionary value at `key` is an error rather than a silent
    /// replacement (the historical bug dropped whole environments on a failed String cast).
    static func merge(environment: [String: String], intoKey key: String, of dictionary: inout [String: Any]) throws {
        guard !environment.isEmpty else { return }
        var existing: [String: Any]
        switch dictionary[key] {
        case nil:
            existing = [:]
        case let dict as [String: Any]:
            existing = dict
        default:
            throw XCTestRunError("xctestrun key '\(key)' is not a dictionary — cannot inject environment")
        }
        for (name, value) in environment {
            existing[name] = value
        }
        dictionary[key] = existing
    }
}
