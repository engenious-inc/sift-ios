import Foundation

public protocol RunnerDelegate: AnyObject {
    func runnerFinished(runner: Runner)
    func handleTestsResults(runner: Runner, executedTests: [String], pathToResults: String?)
    func XCTestRun() -> XCTestRun
    func buildPath() -> String
    func getTests() -> [String]
}
