import Foundation

public protocol XCTestRun: Codable, Sendable {
	var xctestrunFileName: String { get }
	var testRootPath: String { get }
	func testBundleExecPaths(config: String?) -> [(target: String, path: String)]
	func dependentProductPaths(config: String?) -> [String]
	func onlyTestIdentifiers(config: String?) -> [String: [String]]
	func skipTestIdentifiers(config: String?) -> [String: [String]]
	
	mutating func addEnvironmentVariables(_ values: [String: String]?)
    mutating func add(timeout: Int)
	func save(path: String) throws
	func data() throws -> Data
}
