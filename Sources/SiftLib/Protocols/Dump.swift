import Foundation

protocol Dump {
    func dump(path: String, moduleName: String) async throws -> [String]
}
