import Foundation

public enum XCTestRunFactory {

    public static func create(path: String, log: Logging?) throws -> XCTestRun {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw XCTestRunError("xctestrun file not found: \(path)")
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw XCTestRunError("xctestrun is not a valid property list: \(path) — \(error)")
        }
        guard let root = plist as? [String: Any] else {
            throw XCTestRunError("xctestrun root is not a dictionary: \(path)")
        }

        // Dispatch on the declared format version — never reinterpret a failed V2
        // parse as V1: that turns a malformed file into a silent 0-test run.
        let metadata = root["__xctestrun_metadata__"] as? [String: Any]
        let formatVersion = metadata?["FormatVersion"] as? Int ?? 1
        log?.message(verboseMsg: "xctestrun FormatVersion: \(formatVersion)")

        switch formatVersion {
        case 2:
            return try XCTestRunV2(path: path, rawData: data, root: root)
        case 1:
            return try XCTestRunV1(path: path, rawData: data, root: root)
        default:
            throw XCTestRunError("unsupported xctestrun FormatVersion \(formatVersion) in \(path)")
        }
    }
}
