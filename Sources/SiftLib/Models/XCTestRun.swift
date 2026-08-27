import Foundation

public struct XCTestRunError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
    init(_ message: String) { self.message = message }
}

public protocol XCTestRun: Sendable {
    var xctestrunFileName: String { get }
    var testRootPath: String { get }
    func testBundleExecPaths(config: String?) -> [(target: String, path: String)]
    func dependentProductPaths(config: String?) -> [String]
    func onlyTestIdentifiers(config: String?) -> [String: [String]]
    func skipTestIdentifiers(config: String?) -> [String: [String]]
    /// Throws when a requested test configuration name does not exist in the file.
    func validate(configurationName: String?) throws

    mutating func addEnvironmentVariables(_ values: [String: String]?)
    mutating func add(timeout: Int)

    /// Serializes the xctestrun with recorded mutations applied to the ORIGINAL
    /// property-list tree — unmodeled keys survive unchanged.
    func data() throws -> Data
}
