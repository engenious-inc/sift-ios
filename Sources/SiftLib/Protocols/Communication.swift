import Foundation

protocol Communication {
    func getBuildOnRunner(buildPath: String) throws
    func saveOnRunner(xctestrun: XCTestRun) throws -> String
    func executeOnRunner(command: String) throws -> (status: Int32, output: String)
}
