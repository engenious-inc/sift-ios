import Foundation

/// FormatVersion 1 xctestrun (pre-test-plan format): root keys are module names.
/// Same lossless strategy as V2 — typed snapshot for queries, mutations applied
/// to the original tree in `data()`.
public struct XCTestRunV1: XCTestRun {

    struct Module: Sendable {
        var key: String
        var productModuleName: String
        var testBundlePath: String
        var testHostPath: String
        var dependentProductPaths: [String]
        var onlyTestIdentifiers: [String]
        var skipTestIdentifiers: [String]
        var testingEnvironmentVariables: [String: String]
    }

    public let xctestrunFileName: String
    public let testRootPath: String

    private let rawData: Data
    private let modules: [Module]

    private var injectedEnvironment: [String: String] = [:]
    private var injectedTimeout: Int?

    init(path: String, rawData: Data, root: [String: Any]) throws {
        self.rawData = rawData
        let pathComponents = path.components(separatedBy: "/")
        self.xctestrunFileName = pathComponents.last ?? path
        self.testRootPath = pathComponents.dropLast().joined(separator: "/")

        var modules: [Module] = []
        for (key, value) in root where key != "__xctestrun_metadata__" {
            guard let moduleDictionary = value as? [String: Any] else { continue }
            guard let testBundlePath = moduleDictionary["TestBundlePath"] as? String,
                  let testHostPath = moduleDictionary["TestHostPath"] as? String else {
                throw XCTestRunError("xctestrun V1 module '\(key)' is missing TestBundlePath/TestHostPath: \(path)")
            }
            modules.append(Module(
                key: key,
                productModuleName: moduleDictionary["ProductModuleName"] as? String ?? key,
                testBundlePath: testBundlePath,
                testHostPath: testHostPath,
                dependentProductPaths: moduleDictionary["DependentProductPaths"] as? [String] ?? [],
                onlyTestIdentifiers: moduleDictionary["OnlyTestIdentifiers"] as? [String] ?? [],
                skipTestIdentifiers: moduleDictionary["SkipTestIdentifiers"] as? [String] ?? [],
                testingEnvironmentVariables: moduleDictionary["TestingEnvironmentVariables"] as? [String: String] ?? [:]
            ))
        }
        guard !modules.isEmpty else {
            throw XCTestRunError("xctestrun V1 contains no test modules: \(path)")
        }
        self.modules = modules.sorted { $0.key < $1.key }
    }

    // MARK: - Queries

    public func validate(configurationName: String?) throws {
        if let configurationName {
            throw XCTestRunError(
                "onlyTestConfiguration/skipTestConfiguration ('\(configurationName)') is not supported by " +
                "FormatVersion 1 xctestrun files — rebuild with a test plan (FormatVersion 2)"
            )
        }
    }

    public func testBundleExecPaths(config: String?) -> [(target: String, path: String)] {
        modules.map { ($0.productModuleName, executablePath(of: $0)) }
    }

    public func dependentProductPaths(config: String?) -> [String] {
        modules
            .flatMap(\.dependentProductPaths)
            .map { $0.replacingOccurrences(of: "__TESTROOT__", with: testRootPath) }
    }

    public func onlyTestIdentifiers(config: String?) -> [String: [String]] {
        modules.reduce(into: [:]) { result, module in
            if !module.onlyTestIdentifiers.isEmpty {
                result[module.productModuleName] = module.onlyTestIdentifiers
            }
        }
    }

    public func skipTestIdentifiers(config: String?) -> [String: [String]] {
        modules.reduce(into: [:]) { result, module in
            if !module.skipTestIdentifiers.isEmpty {
                result[module.productModuleName] = module.skipTestIdentifiers
            }
        }
    }

    private func executablePath(of module: Module) -> String {
        let hostPath = module.testHostPath.replacingOccurrences(of: "__TESTROOT__", with: testRootPath)
        let bundlePath = module.testBundlePath
            .replacingOccurrences(of: "__TESTHOST__", with: hostPath)
            .replacingOccurrences(of: "__TESTROOT__", with: testRootPath)
        let basename = bundlePath.components(separatedBy: "/").last ?? module.productModuleName
        let executableName = (basename as NSString).deletingPathExtension

        let environment = module.testingEnvironmentVariables
        let dyldPaths = [
            environment["DYLD_FALLBACK_LIBRARY_PATH"],
            environment["DYLD_LIBRARY_PATH"],
            environment["DYLD_FALLBACK_FRAMEWORK_PATH"],
            environment["DYLD_FRAMEWORK_PATH"],
        ].compactMap { $0 }.joined(separator: ":")

        if dyldPaths.contains("MacOSX.platform") || dyldPaths.contains("/MacOS") {
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
        for (key, value) in root where key != "__xctestrun_metadata__" {
            guard var moduleDictionary = value as? [String: Any] else { continue }
            PlistTree.merge(environment: injectedEnvironment, intoKey: "EnvironmentVariables", of: &moduleDictionary)
            if let timeout = injectedTimeout {
                moduleDictionary["TestTimeoutsEnabled"] = true
                moduleDictionary["DefaultTestExecutionTimeAllowance"] = timeout
                moduleDictionary["MaximumTestExecutionTimeAllowance"] = timeout
            }
            root[key] = moduleDictionary
        }
        return try PlistTree.serialize(root)
    }
}
