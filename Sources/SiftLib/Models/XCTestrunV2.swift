import Foundation

/// FormatVersion 2 xctestrun (Xcode 11+ test-plan format).
///
/// Queries are answered from an immutable typed snapshot taken at parse time.
/// Mutations (environment injection, timeouts) are recorded as values and applied
/// to the ORIGINAL property-list tree in `data()`, so every key Sift does not
/// model survives the round trip to the nodes unchanged.
public struct XCTestRunV2: XCTestRun {

    struct Target: Sendable {
        var productModuleName: String
        var testBundlePath: String
        var testHostPath: String
        var dependentProductPaths: [String]
        var onlyTestIdentifiers: [String]
        var skipTestIdentifiers: [String]
        var testingEnvironmentVariables: [String: String]
    }

    struct Configuration: Sendable {
        var name: String?
        var targets: [Target]
    }

    public let xctestrunFileName: String
    public let testRootPath: String

    private let rawData: Data
    private let configurations: [Configuration]

    private var injectedEnvironment: [String: String] = [:]
    private var injectedTimeout: Int?

    init(path: String, rawData: Data, root: [String: Any]) throws {
        self.rawData = rawData
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
                    productModuleName: productModuleName,
                    testBundlePath: testBundlePath,
                    testHostPath: testHostPath,
                    dependentProductPaths: rawTarget["DependentProductPaths"] as? [String] ?? [],
                    onlyTestIdentifiers: rawTarget["OnlyTestIdentifiers"] as? [String] ?? [],
                    skipTestIdentifiers: rawTarget["SkipTestIdentifiers"] as? [String] ?? [],
                    testingEnvironmentVariables: rawTarget["TestingEnvironmentVariables"] as? [String: String] ?? [:]
                )
            }
            return Configuration(name: rawConfiguration["Name"] as? String, targets: targets)
        }
        guard !configurations.isEmpty else {
            throw XCTestRunError("xctestrun V2 contains no test configurations: \(path)")
        }
    }

    // MARK: - Queries

    public func validate(configurationName: String?) throws {
        guard let configurationName else {
            // With several configurations, xcodebuild would run all of them while
            // Sift schedules only the first — later configurations' failures would
            // silently overwrite scheduled verdicts. Refuse the ambiguity.
            if configurations.count > 1 {
                let known = configurations.compactMap(\.name).joined(separator: "', '")
                throw XCTestRunError(
                    "\(xctestrunFileName) contains \(configurations.count) test configurations ('\(known)') — " +
                    "select one with onlyTestConfiguration in the config"
                )
            }
            return
        }
        guard configurations.contains(where: { $0.name == configurationName }) else {
            let known = configurations.compactMap(\.name).joined(separator: "', '")
            throw XCTestRunError(
                "test configuration '\(configurationName)' not found in \(xctestrunFileName); available: '\(known)'"
            )
        }
    }

    private func selectedConfiguration(_ name: String?) -> Configuration? {
        guard let name else { return configurations.first }
        return configurations.first { $0.name == name }
    }

    public func testBundleExecPaths(config: String?) -> [(target: String, path: String)] {
        guard let configuration = selectedConfiguration(config) else { return [] }
        return configuration.targets.map { ($0.productModuleName, executablePath(of: $0)) }
    }

    public func dependentProductPaths(config: String?) -> [String] {
        guard let configuration = selectedConfiguration(config) else { return [] }
        return configuration.targets
            .flatMap(\.dependentProductPaths)
            .map { $0.replacingOccurrences(of: "__TESTROOT__", with: testRootPath) }
    }

    public func onlyTestIdentifiers(config: String?) -> [String: [String]] {
        guard let configuration = selectedConfiguration(config) else { return [:] }
        return configuration.targets.reduce(into: [:]) { result, target in
            if !target.onlyTestIdentifiers.isEmpty {
                result[target.productModuleName] = target.onlyTestIdentifiers
            }
        }
    }

    public func skipTestIdentifiers(config: String?) -> [String: [String]] {
        guard let configuration = selectedConfiguration(config) else { return [:] }
        return configuration.targets.reduce(into: [:]) { result, target in
            if !target.skipTestIdentifiers.isEmpty {
                result[target.productModuleName] = target.skipTestIdentifiers
            }
        }
    }

    /// Path to the test bundle's executable, used by `nm` for test discovery.
    private func executablePath(of target: Target) -> String {
        let bundlePath = target.testBundlePath
            .replacingOccurrences(of: "__TESTHOST__", with: target.testHostPath)
            .replacingOccurrences(of: "__TESTROOT__", with: testRootPath)
        // Bundle executable name = bundle basename minus its extension only —
        // never split on the first dot ("My.App.xctest" → "My.App").
        let basename = bundlePath.components(separatedBy: "/").last ?? target.productModuleName
        let executableName = (basename as NSString).deletingPathExtension

        let environment = target.testingEnvironmentVariables
        let dyldPaths = [
            environment["DYLD_FALLBACK_LIBRARY_PATH"],
            environment["DYLD_LIBRARY_PATH"],
            environment["DYLD_FALLBACK_FRAMEWORK_PATH"],
            environment["DYLD_FRAMEWORK_PATH"],
        ].compactMap { $0 }.joined(separator: ":")

        if dyldPaths.contains("MacOSX.platform") {
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
                PlistTree.merge(environment: injectedEnvironment, intoKey: "EnvironmentVariables", of: &rawTargets[targetIndex])
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

    /// Creates the dictionary when absent — the historical bug was optional-chaining
    /// into a missing EnvironmentVariables dict, silently injecting nothing.
    static func merge(environment: [String: String], intoKey key: String, of dictionary: inout [String: Any]) {
        guard !environment.isEmpty else { return }
        var existing = dictionary[key] as? [String: String] ?? [:]
        existing.merge(environment) { _, new in new }
        dictionary[key] = existing
    }
}
