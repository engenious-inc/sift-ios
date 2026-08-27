import XCTest
@testable import SiftLib

/// Phase 1b: configuration selection algebra, config-tagged scheduling, and
/// configuration-pure leases.
final class MultiConfigurationTests: XCTestCase {

    private func fixture() throws -> any SiftLib.XCTestRun {
        guard let url = Bundle.module.url(forResource: "Fixtures/multi-config.xctestrun", withExtension: nil) else {
            throw XCTSkip("fixture missing")
        }
        return try XCTestRunFactory.create(path: url.path, log: nil)
    }

    // MARK: - Selection algebra: selected = enabled ∩ (only ?? all) ∖ {skip}

    func testSelectionDefaultsToAllEnabledConfigurations() throws {
        let names = try fixture().selectedConfigurationNames(only: nil, skip: nil)
        XCTAssertEqual(names.compactMap { $0 }, ["Config A", "Config B"], "disabled configurations are never selected")
    }

    func testOnlySelectsExactlyOne() throws {
        XCTAssertEqual(try fixture().selectedConfigurationNames(only: "Config B", skip: nil).compactMap { $0 }, ["Config B"])
    }

    func testSkipRemovesOne() throws {
        XCTAssertEqual(try fixture().selectedConfigurationNames(only: nil, skip: "Config A").compactMap { $0 }, ["Config B"])
    }

    func testUnknownOnlyAndSkipAreErrors() throws {
        XCTAssertThrowsError(try fixture().selectedConfigurationNames(only: "Nope", skip: nil))
        XCTAssertThrowsError(try fixture().selectedConfigurationNames(only: nil, skip: "Nope"))
    }

    func testDisabledConfigurationCannotBeSelected() throws {
        XCTAssertThrowsError(try fixture().selectedConfigurationNames(only: "Config Disabled", skip: nil))
    }

    func testOnlyEqualsSkipIsEmptySelectionError() throws {
        XCTAssertThrowsError(try fixture().selectedConfigurationNames(only: "Config A", skip: "Config A")) { error in
            XCTAssertTrue("\(error)".contains("left nothing to run"), "\(error)")
        }
    }

    func testV1RejectsSkipSelector() throws {
        guard let url = Bundle.module.url(forResource: "Fixtures/v1.xctestrun", withExtension: nil) else {
            throw XCTSkip("fixture missing")
        }
        let v1 = try XCTestRunFactory.create(path: url.path, log: nil)
        XCTAssertEqual(try v1.selectedConfigurationNames(only: nil, skip: nil).count, 1)
        XCTAssertThrowsError(try v1.selectedConfigurationNames(only: nil, skip: "Any"))
    }

    // MARK: - Configuration-tagged scheduling

    func testLeasesAreConfigurationPure() async {
        let units = (1...4).map { TestUnit(configuration: "A", test: "M/C/testA\($0)()") }
            + (1...4).map { TestUnit(configuration: "B", test: "M/C/testB\($0)()") }
        let scheduler = TestScheduler(units: units, rerunLimit: 0)
        var leases: [TestLease] = []
        while let lease = await scheduler.lease(maxCount: 3, executorID: "e1") {
            XCTAssertEqual(Set([lease.configuration]).count, 1)
            leases.append(lease)
            await scheduler.complete(lease, outcomes: lease.tests.map { TestOutcome(test: $0, kind: .pass, duration: 1) })
        }
        // Every lease is single-configuration, and every unit ran exactly once.
        for lease in leases {
            XCTAssertNotNil(lease.configuration)
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.passed.count, 8)
    }

    func testSameTestInTwoConfigurationsIsTwoUnitsWithQualifiedNames() async {
        let units = [
            TestUnit(configuration: "A", test: "M/C/testX()"),
            TestUnit(configuration: "B", test: "M/C/testX()"),
        ]
        let scheduler = TestScheduler(units: units, rerunLimit: 0)
        // Fail it in A, pass it in B — verdicts must not overwrite each other.
        while let lease = await scheduler.lease(maxCount: 5, executorID: "e1") {
            let kind: TestOutcome.Kind = lease.configuration == "A" ? .failed : .pass
            await scheduler.complete(lease, outcomes: lease.tests.map { TestOutcome(test: $0, kind: kind) })
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.failed.map(\.name), ["M/C/testX() [A]"])
        XCTAssertEqual(snapshot.passed.map(\.name), ["M/C/testX() [B]"])
    }

    func testSingleConfigurationReportNamesStayPlain() async {
        let scheduler = TestScheduler(units: [TestUnit(configuration: "Config A", test: "M/C/testY()")], rerunLimit: 0)
        let lease = await scheduler.lease(maxCount: 1, executorID: "e1")
        XCTAssertEqual(lease?.configuration, "Config A")
        await scheduler.complete(lease!, outcomes: [TestOutcome(test: "M/C/testY()", kind: .pass)])
        let snapshot = await scheduler.snapshot()
        // One configuration in the whole run → no qualification suffix (back-compat).
        XCTAssertEqual(snapshot.passed.map(\.name), ["M/C/testY()"])
    }

    func testRetryStaysInItsConfiguration() async {
        let units = [
            TestUnit(configuration: "A", test: "M/C/testR()"),
            TestUnit(configuration: "B", test: "M/C/testR()"),
        ]
        let scheduler = TestScheduler(units: units, rerunLimit: 1)
        var attempts: [(String?, String)] = []
        while let lease = await scheduler.lease(maxCount: 1, executorID: "e1") {
            attempts.append((lease.configuration, lease.tests[0]))
            // Fail only configuration A; its retry must come back tagged A.
            let kind: TestOutcome.Kind = lease.configuration == "A" ? .failed : .pass
            await scheduler.complete(lease, outcomes: [TestOutcome(test: lease.tests[0], kind: kind)])
        }
        XCTAssertEqual(attempts.filter { $0.0 == "A" }.count, 2, "A failed once and retried once")
        XCTAssertEqual(attempts.filter { $0.0 == "B" }.count, 1)
    }
}
