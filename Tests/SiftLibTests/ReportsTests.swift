import XCTest
@testable import SiftLib

final class ReportsTests: XCTestCase {

    private func makeSnapshot() -> TestCasesSnapshot {
        TestCasesSnapshot(cases: [
            TestCase(name: "ModuleA/ClassA/testPass()", state: .pass, launchCounter: 1, infrastructureAttempts: 0, duration: 1.5, message: ""),
            TestCase(name: "ModuleA/ClassA/testFail()", state: .failed, launchCounter: 2, infrastructureAttempts: 0, duration: 2.0,
                     message: "assertion <failed> & \"broken\" 'here'\nsecond line"),
            TestCase(name: "ModuleA/ClassABC/testOther()", state: .pass, launchCounter: 1, infrastructureAttempts: 0, duration: 0.5, message: ""),
            TestCase(name: "ModuleB/ClassB/testSkip()", state: .skipped, launchCounter: 1, infrastructureAttempts: 0, duration: 0, message: "skip reason"),
            TestCase(name: "ModuleB/ClassB/testNever()", state: .unexecuted, launchCounter: 0, infrastructureAttempts: 2, duration: 0, message: ""),
        ])
    }

    func testJUnitIsValidSingleRootXML() throws {
        let xml = JUnit().generate(tests: makeSnapshot())
        // Must parse as XML (escaping correct, single root).
        let document = try XMLDocument(xmlString: xml)
        XCTAssertEqual(document.rootElement()?.name, "testsuites")
        XCTAssertEqual(document.rootElement()?.attribute(forName: "tests")?.stringValue, "5")
        XCTAssertEqual(document.rootElement()?.attribute(forName: "failures")?.stringValue, "1")
        XCTAssertEqual(document.rootElement()?.attribute(forName: "errors")?.stringValue, "1")
        XCTAssertEqual(document.rootElement()?.attribute(forName: "skipped")?.stringValue, "1")
    }

    func testJUnitExactSuiteGroupingNoPrefixCollision() throws {
        let xml = JUnit().generate(tests: makeSnapshot())
        let document = try XMLDocument(xmlString: xml)
        let suites = try document.nodes(forXPath: "//testsuite") as! [XMLElement]
        let names = suites.compactMap { $0.attribute(forName: "name")?.stringValue }.sorted()
        // ClassA and ClassABC are distinct suites — no hasPrefix bleeding.
        XCTAssertEqual(names, ["ModuleA.ClassA", "ModuleA.ClassABC", "ModuleB.ClassB"])
        let classA = suites.first { $0.attribute(forName: "name")?.stringValue == "ModuleA.ClassA" }
        XCTAssertEqual(classA?.attribute(forName: "tests")?.stringValue, "2")
    }

    func testJUnitStateMapping() throws {
        let xml = JUnit().generate(tests: makeSnapshot())
        let document = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try document.nodes(forXPath: "//failure").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "//skipped").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "//error").count, 1)
        // Failure body preserved through escaping.
        let failure = try document.nodes(forXPath: "//failure").first as! XMLElement
        XCTAssertTrue(failure.stringValue!.contains("assertion <failed> & \"broken\" 'here'"))
    }

    private func makeContext(duration: Double = 12.5) -> ReportContext {
        ReportContext(
            duration: duration, executionDuration: duration - 2, hostname: "test-host",
            mergeStatus: "merged",
            healthEvents: [RunHealthEvent(kind: .executorRetired, source: "n/UDID", detail: "3 failures")],
            retainedArtifacts: ["final/diagnostics/failed-ingest/x.zip"]
        )
    }

    func testJSONReportCountsAndStableOrdering() throws {
        let report = JSONReport.generate(tests: makeSnapshot(), context: makeContext())
        XCTAssertEqual(report.summary.tests, 5)
        XCTAssertEqual(report.summary.passed, 2)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
        XCTAssertEqual(report.summary.unexecuted, 1)
        XCTAssertEqual(report.summary.rerunned, 1)
        XCTAssertEqual(report.results.map(\.testSuite),
                       ["ModuleA/ClassA", "ModuleA/ClassABC", "ModuleB/ClassB"])
    }

    func testJSONReportSchema3AdditiveFields() throws {
        let report = JSONReport.generate(tests: makeSnapshot(), context: makeContext())
        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(report.hostname, "test-host")
        XCTAssertEqual(report.mergeStatus, "merged")
        XCTAssertEqual(report.healthEvents.count, 1)
        XCTAssertEqual(report.retainedArtifacts, ["final/diagnostics/failed-ingest/x.zip"])
        XCTAssertEqual(report.summary.executionDuration, 10.5)
        XCTAssertEqual(report.results.map(\.className),
                       ["ModuleA.ClassA", "ModuleA.ClassABC", "ModuleB.ClassB"])
        // Unexecuted reasons are no longer dropped.
        let suiteB = report.results.first { $0.testSuite == "ModuleB/ClassB" }
        XCTAssertEqual(suiteB?.unexecutedDetails.count, 1)
        XCTAssertEqual(suiteB?.unexecutedDetails.first?.infrastructureAttempts, 2)
        // Legacy fields keep their shapes.
        XCTAssertEqual(suiteB?.unexecutedTests, ["ModuleB/ClassB/testNever()"])
    }

    func testJUnitHostnameTimestampAndControlCharacterSanitization() throws {
        let snapshot = TestCasesSnapshot(cases: [
            TestCase(name: "M/C/testCtl()", state: .failed, launchCounter: 1, infrastructureAttempts: 0,
                     duration: 1, message: "bad \u{07}bell and \u{1B}[31mansi\u{0000} chars"),
        ])
        let xml = JUnit().generate(tests: snapshot, hostname: "host-x", timestamp: Date(timeIntervalSince1970: 0))
        // Must parse even though the message contained XML-illegal scalars.
        let document = try XMLDocument(xmlString: xml)
        XCTAssertEqual(document.rootElement()?.attribute(forName: "timestamp")?.stringValue, "1970-01-01T00:00:00Z")
        let suite = try document.nodes(forXPath: "//testsuite").first as! XMLElement
        XCTAssertEqual(suite.attribute(forName: "hostname")?.stringValue, "host-x")
        let failure = try document.nodes(forXPath: "//failure").first as! XMLElement
        XCTAssertFalse(failure.stringValue!.contains("\u{07}"))
        XCTAssertTrue(failure.stringValue!.contains("ansi"))
    }

    func testJSONAttemptsAreDeterministicallyOrdered() throws {
        let base = Date(timeIntervalSince1970: 100)
        let attempts = [
            TestAttempt(test: "M/C/b()", executorID: "e2", kind: .pass, duration: 1, message: "", startedAt: base, endedAt: base),
            TestAttempt(test: "M/C/a()", executorID: "e1", kind: .pass, duration: 1, message: "", startedAt: base, endedAt: base),
            TestAttempt(test: "M/C/a()", executorID: "e0", kind: .pass, duration: 1, message: "", startedAt: Date(timeIntervalSince1970: 50), endedAt: base),
        ]
        let snapshot = TestCasesSnapshot(cases: [], attempts: attempts)
        let report = JSONReport.generate(tests: snapshot, context: makeContext())
        XCTAssertEqual(report.attempts.map(\.executor), ["e0", "e1", "e2"])
    }
}
