import Foundation

public protocol TestExecutor: AnyObject {
    var type: TestExecutorType { get }
    var UDID: String { get }
    
    func ready() async -> Bool
    func run(tests: [String]) async -> (TestExecutor, Result<[String], TestExecutorError>)
    @discardableResult
    func reset() async -> Result<TestExecutor, Error>
    func deleteApp(bundleId: String) async
}

public enum TestExecutorType: String {
    case simulator = "iOS Simulator"
    case device = "iOS"
	case macOS = "macOS"
}

public enum TestExecutorError: Error {
    case noTestsForExecution
    case executionError(description: String, tests: [String])
    case testSkipped
}
