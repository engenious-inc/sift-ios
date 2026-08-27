import Foundation

// MARK: - JSONReportModel
struct JSONReportModel: Codable {
    /// Schema version: 2 adds `rerun` (correct spelling; `rerunned` is kept for
    /// one compatibility release) and the `attempts` history.
    var schemaVersion: Int = 2
    var summary: Summary
    var results: [Result] = []
    var attempts: [Attempt] = []
}

extension JSONReportModel {
    // MARK: - Result
    struct Result: Codable {
        var testSuite: String
        var passed, rerunned, skipped, failed, unexecuted: Int
        var rerun: Int
        var passedTests: [PassedTest]
        var rerunnedTests: [String]
        var skippedTests: [String]
        var failedTests: [FailedTest]
        var unexecutedTests: [String]

        init(testSuite: String, passed: Int, rerunned: Int, skipped: Int, failed: Int, unexecuted: Int,
             passedTests: [PassedTest], rerunnedTests: [String], skippedTests: [String],
             failedTests: [FailedTest], unexecutedTests: [String]) {
            self.testSuite = testSuite
            self.passed = passed
            self.rerunned = rerunned
            self.rerun = rerunned
            self.skipped = skipped
            self.failed = failed
            self.unexecuted = unexecuted
            self.passedTests = passedTests
            self.rerunnedTests = rerunnedTests
            self.skippedTests = skippedTests
            self.failedTests = failedTests
            self.unexecutedTests = unexecutedTests
        }
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
        var tests, passed, rerunned, skipped, failed, unexecuted: Int
        var rerun: Int
        var duration: Double

        init(tests: Int, passed: Int, rerunned: Int, skipped: Int, failed: Int, unexecuted: Int, duration: Double) {
            self.tests = tests
            self.passed = passed
            self.rerunned = rerunned
            self.rerun = rerunned
            self.skipped = skipped
            self.failed = failed
            self.unexecuted = unexecuted
            self.duration = duration
        }
    }

    // MARK: - Attempt
    struct Attempt: Codable {
        var test: String
        var executor: String
        var outcome: String
        var duration: Double
        var message: String
    }
}

extension JSONReportModel {

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
