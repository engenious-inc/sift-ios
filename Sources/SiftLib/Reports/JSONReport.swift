import Foundation

enum JSONReport {

    static func generate(tests: TestCasesSnapshot, duration: Double) -> JSONReportModel {
        let testsBySuite: [String: [TestCase]] = tests.cases
            .reduce(into: [:]) { result, testCase in
                let suiteName = testCase.name.components(separatedBy: "/").dropLast().joined(separator: "/")
                result[suiteName, default: []].append(testCase)
            }

        let reportSummary = JSONReportModel.Summary(
            tests: tests.count,
            passed: tests.passed.count,
            rerunned: tests.rerun.count,
            skipped: tests.skipped.count,
            failed: tests.failed.count,
            unexecuted: tests.unexecuted.count,
            duration: duration
        )

        var report = JSONReportModel(summary: reportSummary)
        for suiteName in testsBySuite.keys.sorted() {
            let suite = testsBySuite[suiteName] ?? []
            let sorted = suite.sorted { $0.name < $1.name }
            let result = JSONReportModel.Result(
                testSuite: suiteName,
                passed: sorted.filter { $0.state == .pass }.count,
                rerunned: sorted.filter { $0.launchCounter > 1 }.count,
                skipped: sorted.filter { $0.state == .skipped }.count,
                failed: sorted.filter { $0.state == .failed }.count,
                unexecuted: sorted.filter { $0.state == .unexecuted }.count,
                passedTests: sorted.filter { $0.state == .pass }.map { .init(test: $0.name, duration: $0.duration) },
                rerunnedTests: sorted.filter { $0.launchCounter > 1 }.map(\.name),
                skippedTests: sorted.filter { $0.state == .skipped }.map(\.name),
                failedTests: sorted.filter { $0.state == .failed }.map { .init(test: $0.name, message: $0.message, duration: $0.duration) },
                unexecutedTests: sorted.filter { $0.state == .unexecuted }.map(\.name)
            )
            report.results.append(result)
        }
        return report
    }
}
