import Foundation

enum JSONReport {

    static func generate(tests: TestCasesSnapshot, context: ReportContext) -> JSONReportModel {
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
            duration: context.duration,
            executionDuration: context.executionDuration
        )

        var report = JSONReportModel(summary: reportSummary)
        report.hostname = context.hostname
        report.mergeStatus = context.mergeStatus
        report.healthEvents = context.healthEvents
        report.retainedArtifacts = context.retainedArtifacts
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
                unexecutedTests: sorted.filter { $0.state == .unexecuted }.map(\.name),
                unexecutedDetails: sorted.filter { $0.state == .unexecuted }.map {
                    .init(test: $0.name, message: $0.message, infrastructureAttempts: $0.infrastructureAttempts)
                }
            )
            report.results.append(result)
        }
        // Deterministic order: identical runs produce identical JSON.
        let sortedAttempts = tests.attempts.sorted {
            ($0.startedAt, $0.test, $0.executorID, $0.endedAt) < ($1.startedAt, $1.test, $1.executorID, $1.endedAt)
        }
        report.attempts = sortedAttempts.map {
            JSONReportModel.Attempt(
                test: $0.test,
                executor: $0.executorID,
                outcome: outcomeName($0.kind),
                duration: $0.duration,
                message: $0.message,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt
            )
        }
        return report
    }

    private static func outcomeName(_ kind: TestOutcome.Kind) -> String {
        switch kind {
        case .pass: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .notExecuted: return "notExecuted"
        }
    }
}
