import Foundation

protocol Communication: Sendable {
    func connect() async throws
    func getBuildOnRunner(buildPath: String) async throws
    func saveOnRunner(xctestrun: XCTestRun) async throws -> String
    func executeOnRunner(command: String) async throws -> (status: Int32, output: String)
    func cleanup() async
}
