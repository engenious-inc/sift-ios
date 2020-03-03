import Foundation

protocol Communication {
    func getBuildOnRunner(buildPath: String) throws
    func sendResultsToMaster(UDID: String) throws -> String?
    func saveOnRunner(xctestrun: XCTestRun) throws -> String
}
