import Foundation

enum JSONReport {
    
    static func generate(tests: TestCases, duration: Double) async -> JSONReportModel {
        
        let testsBySuite: [String: [TestCase]] = await tests.cases.values
            .reduce(into: [String: [TestCase]]()) { result, testCase in
            let suiteName = testCase.name.components(separatedBy: "/").dropLast().joined(separator: "/")
            result[suiteName, default: []].append(testCase)
        }
        
        let reportSummary = await JSONReportModel.Summary(tests: await tests.count,
                                passed: tests.passed.count,
                                rerunned: tests.reran.count,
                                failed: tests.failed.count,
                                unexecuted: tests.unexecuted.count,
                                duration: duration)
        
        var report = JSONReportModel(summary: reportSummary)
        report = testsBySuite.reduce(into: report) { report, suite in
            let passed = suite.value.filter { $0.state == .pass }.count
            let rerunned = suite.value.filter { $0.launchCounter > 1 }.count
            let failed = suite.value.filter { $0.state == .failed }.count
            let unexecuted = suite.value.filter { $0.state == .unexecuted }.count
            let passedTests = suite.value.filter { $0.state == .pass }.map { JSONReportModel.PassedTest(test: $0.name, duration: $0.duration) }
            let rerunnedTests = suite.value.filter { $0.launchCounter > 1 }.map { $0.name }
            let failedTests = suite.value.filter { $0.state == .failed }.map { JSONReportModel.FailedTest(test: $0.name, message: $0.message, duration: $0.duration) }
            let unexecutedTests = suite.value.filter { $0.state == .unexecuted }.map { $0.name }
            
            let testResults = JSONReportModel.Result(testSuite: suite.key,
                                                     passed: passed,
                                                     rerunned: rerunned,
                                                     failed: failed,
                                                     unexecuted: unexecuted,
                                                     passedTests: passedTests,
                                                     rerunnedTests: rerunnedTests,
                                                     failedTests: failedTests,
                                                     unexecutedTests: unexecutedTests)
            report.results.append(testResults)
        }
        
        return report
    }
}
