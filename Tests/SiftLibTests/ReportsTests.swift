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

    func testJSONReportCountsAndStableOrdering() throws {
        let report = JSONReport.generate(tests: makeSnapshot(), duration: 12.5)
        XCTAssertEqual(report.summary.tests, 5)
        XCTAssertEqual(report.summary.passed, 2)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
        XCTAssertEqual(report.summary.unexecuted, 1)
        XCTAssertEqual(report.summary.rerunned, 1)
        XCTAssertEqual(report.results.map(\.testSuite),
                       ["ModuleA/ClassA", "ModuleA/ClassABC", "ModuleB/ClassB"])
    }
}
