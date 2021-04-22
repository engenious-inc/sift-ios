import Foundation

public protocol XCTestRun: Codable {
	var xctestrunFileName: String { get }
	var testRootPath: String { get }
	var testBundleExecPaths: [(target: String, path: String)] { get }
	var dependentProductPaths: [String] { get }
	var onlyTestIdentifiers: [String: [String]] { get }
	var skipTestIdentifiers: [String: [String]] { get }
	
	mutating func addEnvironmentVariables(_ values: [String: String]?)
	func save(path: String) throws
	func data() throws -> Data
}
