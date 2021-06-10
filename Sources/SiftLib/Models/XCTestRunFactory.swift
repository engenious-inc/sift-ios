import Foundation

public enum XCTestRunFactory {
	
	public static func `init`(path: String) throws -> XCTestRun {
		return try (try? XCTestRunV2(path: path)) ?? XCTestRunV1(path: path)
	}
}
