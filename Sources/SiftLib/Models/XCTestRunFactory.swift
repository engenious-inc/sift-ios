import Foundation

public enum XCTestRunFactory {
	
    public static func create(path: String, log: Logging?) throws -> XCTestRun {
        do {
            return try XCTestRunV2(path: path)
        } catch {
            log?.message(verboseMsg: "Can't parse xctestrun V2")
        }
        
        do {
            return try XCTestRunV1(path: path)
        } catch {
            log?.message(verboseMsg: "Can't parse xctestrun V1")
        }
        
		throw NSError(domain: "Can't parse xctestrun as V1 or V2", code: 1)
	}
}
