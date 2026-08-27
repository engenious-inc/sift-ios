import Foundation

// MARK: - JSONReportModel
struct JSONReportModel: Codable {
    /// Schema version 3 (additive over 2): `hostname`, `mergeStatus`, `healthEvents`,
    /// `retainedArtifacts`, `summary.executionDuration`, `results[].className`,
    /// `results[].bundleName`, `results[].configuration`, `results[].unexecutedDetails`.
    /// Version 2 added `rerun` + `attempts`.
    var schemaVersion: Int = 3
    var summary: Summary
    var hostname: String = ""
    /// "merged" | "failed" | "nothingToMerge"
    var mergeStatus: String = "nothingToMerge"
    var healthEvents: [RunHealthEvent] = []
    /// final/-relative paths kept for post-mortems (failed-ingest archives, raw
    /// bundles after a failed merge, unhealthy-chunk logs live under final/logs).
    var retainedArtifacts: [String] = []
    var results: [Result] = []
    var attempts: [Attempt] = []
}

extension JSONReportModel {
    // MARK: - Result
    struct Result: Codable {
        var testSuite: String
        /// Dotted form matching JUnit's classname ("Bundle.Class") — `testSuite`
        /// keeps its historical slash form.
        var className: String
        /// `.xctest` bundle basename — the first identifier component.
        var bundleName: String
        /// Test-plan configuration this suite's tests ran under (null: none recorded).
        var configuration: String?
        var passed, rerunned, skipped, failed, unexecuted: Int
        var rerun: Int
        var passedTests: [PassedTest]
        var rerunnedTests: [String]
        var skippedTests: [String]
        var failedTests: [FailedTest]
        var unexecutedTests: [String]
        /// Unexecuted tests WITH their infrastructure reason (unexecutedTests keeps
        /// its historical string-array shape).
        var unexecutedDetails: [UnexecutedTest]

        init(testSuite: String, configuration: String? = nil,
             passed: Int, rerunned: Int, skipped: Int, failed: Int, unexecuted: Int,
             passedTests: [PassedTest], rerunnedTests: [String], skippedTests: [String],
             failedTests: [FailedTest], unexecutedTests: [String], unexecutedDetails: [UnexecutedTest] = []) {
            self.testSuite = testSuite
            self.className = testSuite.replacingOccurrences(of: "/", with: ".")
            self.bundleName = testSuite.components(separatedBy: "/").first ?? testSuite
            self.configuration = configuration
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
            self.unexecutedDetails = unexecutedDetails
        }
    }

    // MARK: - UnexecutedTest
    struct UnexecutedTest: Codable {
        var test: String
        var message: String
        var infrastructureAttempts: Int
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
        /// End-to-end wall time (merge + reports included).
        var duration: Double
        /// Test-execution span only (until the scheduler drained).
        var executionDuration: Double

        init(tests: Int, passed: Int, rerunned: Int, skipped: Int, failed: Int, unexecuted: Int,
             duration: Double, executionDuration: Double = 0) {
            self.tests = tests
            self.passed = passed
            self.rerunned = rerunned
            self.rerun = rerunned
            self.skipped = skipped
            self.failed = failed
            self.unexecuted = unexecuted
            self.duration = duration
            self.executionDuration = executionDuration
        }
    }

    // MARK: - Attempt
    struct Attempt: Codable {
        var test: String
        var executor: String
        var outcome: String
        var duration: Double
        var message: String
        var startedAt: Date
        var endedAt: Date
    }
}

extension JSONReportModel {

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
