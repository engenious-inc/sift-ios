import Foundation

// MARK: - JSONReportModel
struct JSONReportModel: Codable {
    var summary: Summary
    var results: [Result] = []
}

extension JSONReportModel {
    // MARK: - Result
    struct Result: Codable {
        var testSuite: String
        var passed, rerunned, failed, unexecuted: Int
        var passedTests: [PassedTest]
        var rerunnedTests: [String]
        var failedTests: [FailedTest]
        var unexecutedTests: [String]
    }

    // MARK: - FailedTest
    struct FailedTest: Codable {
        var test, message: String
        var duration: Double
    }

    // MARK: - PassedTest
    struct PassedTest: Codable {
        var test: String
        var duration: Double
    }

    // MARK: - Summary
    struct Summary: Codable {
        var tests, passed, rerunned, failed, unexecuted: Int
        var duration: Double
    }
}

extension JSONReportModel {
    
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}
