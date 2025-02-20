import Foundation

protocol Communication: Sendable {
    func getBuildOnRunner(buildPath: String) async throws
    func saveOnRunner(xctestrun: XCTestRun) throws -> String
    func executeOnRunner(command: String) async throws -> (status: Int32, output: String)
}
