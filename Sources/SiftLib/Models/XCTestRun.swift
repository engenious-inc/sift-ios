import Foundation

public struct XCTestRunError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
    init(_ message: String) { self.message = message }
}

/// Platform an xctestrun's products were built for, derived from its recorded paths.
public enum TestPlatform: String, Sendable {
    case simulator
    case device
    case macOS

    /// Executor categories this artifact can legally run on.
    var allowedExecutorTypes: Set<TestExecutorType> {
        switch self {
        case .simulator: return [.simulator]
        case .device: return [.device]
        case .macOS: return [.macOS]
        }
    }

    public var displayName: String {
        switch self {
        case .simulator: return "iOS Simulator"
        case .device: return "iOS device"
        case .macOS: return "macOS"
        }
    }

    /// Derives the platform from a target's test-host path and DYLD search paths.
    /// Returns nil when no marker is recognizable — callers must treat that as an error,
    /// never guess.
    static func derive(testHostPath: String, dyldPaths: String) -> TestPlatform? {
        let haystack = testHostPath + ":" + dyldPaths
        if haystack.contains("-iphonesimulator") || haystack.contains("iPhoneSimulator.platform") {
            return .simulator
        }
        if haystack.contains("-iphoneos") || haystack.contains("iPhoneOS.platform") {
            return .device
        }
        if haystack.contains("MacOSX.platform") || haystack.contains("-macosx") || haystack.contains("/Contents/MacOS") {
            return .macOS
        }
        return nil
    }
}

/// One test bundle inside an xctestrun, with every name Sift needs:
/// `bundleName` (the `.xctest` basename) is the canonical identifier namespace —
/// it is what `xcodebuild -only-testing:` matches and what xcresult reports under.
/// `productModuleName` is kept only for symbol-level concerns.
public struct TestBundleDescriptor: Sendable, Hashable {
    /// V1: the root dictionary key. V2: BlueprintName (falling back to ProductModuleName).
    public let targetKey: String
    public let productModuleName: String
    /// `.xctest` bundle basename without extension.
    public let bundleName: String
    /// Absolute path of the bundle's binary (for `nm`-based discovery).
    public let executablePath: String

    public init(targetKey: String, productModuleName: String, bundleName: String, executablePath: String) {
        self.targetKey = targetKey
        self.productModuleName = productModuleName
        self.bundleName = bundleName
        self.executablePath = executablePath
    }
}

public protocol XCTestRun: Sendable {
    var xctestrunFileName: String { get }
    var xctestrunPath: String { get }
    var testRootPath: String { get }
    /// Platform the recorded products were built for. Throws when underivable.
    func platform() throws -> TestPlatform
    func testBundles(config: String?) -> [TestBundleDescriptor]
    func dependentProductPaths(config: String?) -> [String]
    /// Keyed by BUNDLE name (not ProductModuleName).
    func onlyTestIdentifiers(config: String?) -> [String: [String]]
    /// Keyed by BUNDLE name (not ProductModuleName).
    func skipTestIdentifiers(config: String?) -> [String: [String]]
    /// Throws when a requested test configuration name does not exist in the file.
    func validate(configurationName: String?) throws

    mutating func addEnvironmentVariables(_ values: [String: String]?)
    mutating func add(timeout: Int)

    /// Serializes the xctestrun with recorded mutations applied to the ORIGINAL
    /// property-list tree — unmodeled keys survive unchanged.
    func data() throws -> Data
}

extension TestBundleDescriptor {
    /// "My UITests.xctest" → "My UITests"; never splits on the first dot.
    static func bundleName(fromBundlePath path: String) -> String {
        let basename = path.components(separatedBy: "/").last ?? path
        return (basename as NSString).deletingPathExtension
    }
}
