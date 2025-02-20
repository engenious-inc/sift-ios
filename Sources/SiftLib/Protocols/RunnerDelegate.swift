import Foundation

public protocol RunnerDelegate: Sendable {
    func handleTestsResults(runner: Runner, executedTests: [String], pathToResults: String?) async
    func XCTestRun() throws -> XCTestRun
    func buildPath() async -> String
    func getTests() async -> [String]
}
