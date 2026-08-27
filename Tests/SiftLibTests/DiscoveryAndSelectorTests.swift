import XCTest
@testable import SiftLib

/// Phase 1a coverage: enumeration parsing, the bundle-name namespace, selector
/// parsing/expansion, and static-method rejection in the transitional symbol backend.
final class DiscoveryAndSelectorTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw XCTSkip("fixture \(name) missing")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Enumeration JSON parsing

    func testEnumerationParsingAgainstRecordedBulkOutput() throws {
        let document = try JSONDecoder().decode(
            TestDiscovery.EnumerationDocument.self,
            from: try fixtureData("enumerated-tests-bulk.json")
        )
        let descriptors = [TestBundleDescriptor(
            targetKey: "BulkTest", productModuleName: "BulkTest",
            bundleName: "BulkTest", executablePath: "/dev/null"
        )]
        let tests = try TestDiscovery.scheduledTests(
            fromEnumeration: document, configuration: nil, descriptors: descriptors, log: nil
        )
        XCTAssertEqual(tests.count, 30)
        XCTAssertTrue(tests.contains { $0.id == "BulkTest/BulkTest/testExample_1()" })
        XCTAssertEqual(tests.first?.bundleName, "BulkTest")
    }

    func testEnumerationSpaceNamedTargetUsesBundleNamespace() throws {
        let document = try JSONDecoder().decode(
            TestDiscovery.EnumerationDocument.self,
            from: try fixtureData("enumerated-tests-space-target.json")
        )
        let descriptors = [
            TestBundleDescriptor(targetKey: "My UITests", productModuleName: "My_UITests",
                                 bundleName: "My UITests", executablePath: "/dev/null"),
            TestBundleDescriptor(targetKey: "ObjCTests", productModuleName: "ObjCTests",
                                 bundleName: "ObjCTests", executablePath: "/dev/null"),
        ]
        let tests = try TestDiscovery.scheduledTests(
            fromEnumeration: document, configuration: nil, descriptors: descriptors, log: nil
        )
        // The identifier namespace is the BUNDLE name ("My UITests"), never the
        // product module name ("My_UITests").
        XCTAssertTrue(tests.contains { $0.id == "My UITests/LoginTests/testLogin()" })
        let login = tests.first { $0.method == "testLogin()" }
        XCTAssertEqual(login?.productModuleName, "My_UITests")
        // Nested class path survives flat enumeration.
        XCTAssertTrue(tests.contains { $0.id == "My UITests/Outer/Inner/testNested()" })
        // ObjC tests are first-class citizens of enumeration.
        XCTAssertTrue(tests.contains { $0.id == "ObjCTests/LegacyObjCTests/testObjCStyleAssertion()" })
        // Plan-disabled tests are never scheduled.
        XCTAssertFalse(tests.contains { $0.method == "testDisabledByPlan()" })
        XCTAssertEqual(tests.count, 4)
    }

    func testEnumerationErrorsAreFatalEvenWithExitZero() throws {
        // xcodebuild exits 0 while reporting "Tests must be run on a concrete device"
        // only inside `errors` — the parser layer must treat that as failure. The
        // fatal decision lives in enumerationTests; here we pin the document shape.
        let json = #"{"errors":["Cannot test target X"],"values":[]}"#.data(using: .utf8)!
        let document = try JSONDecoder().decode(TestDiscovery.EnumerationDocument.self, from: json)
        XCTAssertEqual(document.errors, ["Cannot test target X"])
    }

    /// End-to-end namespace agreement: the id discovery schedules is byte-identical to
    /// the id XCResultTool reports, for a space-named target — the exact shape that used
    /// to break `coversLease`.
    func testScheduledIdMatchesXCResultOutcomeIdForSpaceNamedTarget() throws {
        let resultJSON = """
        {"testNodes":[{"nodeType":"Test Plan","name":"AllTests","children":[
          {"nodeType":"UI test bundle","name":"My UITests","children":[
            {"nodeType":"Test Suite","name":"LoginTests","children":[
              {"nodeType":"Test Case","name":"testLogin()","nodeIdentifier":"LoginTests/testLogin()","result":"Passed","durationInSeconds":1.5}
            ]}]}]}]}
        """.data(using: .utf8)!
        let outcomes = try XCResultTool.outcomes(fromTestResultsJSON: resultJSON)
        XCTAssertEqual(outcomes.count, 1)

        let scheduled = ScheduledTest(
            configurationName: nil, targetKey: "My UITests", productModuleName: "My_UITests",
            bundleName: "My UITests", classPath: "LoginTests", method: "testLogin()"
        )
        XCTAssertEqual(outcomes[0].test, scheduled.id)
    }

    // MARK: - Selector parsing

    func testSelectorParsing() {
        XCTAssertEqual(TestSelector.parse("BulkTest"), .bundle("BulkTest"))
        XCTAssertEqual(TestSelector.parse("BulkTest/BulkTest"), .classOrMethod(bundle: "BulkTest", components: ["BulkTest"]))
        // Paren-less multi-component selectors stay AMBIGUOUS (class or method) —
        // resolved against discovered identities at match time, never by heuristic.
        XCTAssertEqual(TestSelector.parse("M/C/testA"), .classOrMethod(bundle: "M", components: ["C", "testA"]))
        XCTAssertEqual(TestSelector.parse("M/C/testA()"), .method(bundle: "M", classPath: "C", method: "testA()"))
        XCTAssertEqual(TestSelector.parse("M/Outer/Inner/testX"), .classOrMethod(bundle: "M", components: ["Outer", "Inner", "testX"]))
        XCTAssertEqual(TestSelector.parse("M/Outer/Inner"), .classOrMethod(bundle: "M", components: ["Outer", "Inner"]))
        XCTAssertEqual(TestSelector.parse("My UITests/LoginTests/testLogin()"),
                       .method(bundle: "My UITests", classPath: "LoginTests", method: "testLogin()"))
        XCTAssertNil(TestSelector.parse("   "))
    }

    /// The dual reading in action: a paren-less name reaches a suite-less Swift
    /// Testing FUNCTION, and a class whose name starts with "test" stays reachable.
    func testAmbiguousSelectorMatchesBothClassAndMethodReadings() throws {
        let suiteLess = ScheduledTest(configurationName: nil, targetKey: "S", productModuleName: "S",
                                      bundleName: "S", classPath: "", method: "modernAdditionWorks()")
        let oddClass = ScheduledTest(configurationName: nil, targetKey: "S", productModuleName: "S",
                                     bundleName: "S", classPath: "testHelpers", method: "testInside()")
        // Method reading: no parens, no "test" prefix — still reaches the free function.
        XCTAssertEqual(try TestSelector.expand(rawSelectors: ["S/modernAdditionWorks"], against: [suiteLess, oddClass]),
                       [suiteLess])
        // Class reading: a "test"-prefixed CLASS selects its methods, not a phantom method.
        XCTAssertEqual(try TestSelector.expand(rawSelectors: ["S/testHelpers"], against: [suiteLess, oddClass]),
                       [oddClass])
    }

    // MARK: - Selector expansion

    private var discovered: [ScheduledTest] {
        [
            ScheduledTest(configurationName: nil, targetKey: "M", productModuleName: "M",
                          bundleName: "M", classPath: "ClassA", method: "testOne()"),
            ScheduledTest(configurationName: nil, targetKey: "M", productModuleName: "M",
                          bundleName: "M", classPath: "ClassA", method: "testTwo()"),
            ScheduledTest(configurationName: nil, targetKey: "M", productModuleName: "M",
                          bundleName: "M", classPath: "ClassB", method: "testThree()"),
            ScheduledTest(configurationName: nil, targetKey: "N", productModuleName: "N",
                          bundleName: "N", classPath: "ClassA", method: "testFour()"),
        ]
    }

    func testClassSelectorExpandsToItsMethodsOnly() throws {
        let expanded = try TestSelector.expand(rawSelectors: ["M/ClassA"], against: discovered)
        XCTAssertEqual(expanded.map(\.id).sorted(), ["M/ClassA/testOne()", "M/ClassA/testTwo()"])
    }

    func testBundleSelectorExpandsToWholeBundle() throws {
        let expanded = try TestSelector.expand(rawSelectors: ["M"], against: discovered)
        XCTAssertEqual(expanded.count, 3)
    }

    func testMethodSelectorWithAndWithoutParens() throws {
        let expanded = try TestSelector.expand(rawSelectors: ["M/ClassB/testThree", "M/ClassA/testOne()"], against: discovered)
        XCTAssertEqual(expanded.map(\.id).sorted(), ["M/ClassA/testOne()", "M/ClassB/testThree()"])
    }

    func testDuplicateSelectorsDeduplicate() throws {
        let expanded = try TestSelector.expand(rawSelectors: ["M/ClassA", "M/ClassA/testOne()"], against: discovered)
        XCTAssertEqual(expanded.count, 2)
    }

    func testUnknownSelectorIsErrorWithSuggestions() {
        XCTAssertThrowsError(try TestSelector.expand(rawSelectors: ["M/ClassA/testOnee"], against: discovered)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("testOnee"), message)
            XCTAssertTrue(message.contains("M/ClassA/testOne()"), "should suggest close match: \(message)")
        }
        // A class-level typo is also a selection error, not a silent no-op.
        XCTAssertThrowsError(try TestSelector.expand(rawSelectors: ["M/ClasA"], against: discovered))
    }

    // MARK: - Symbol backend: static/class rejection (phantom-test bug)

    func testStaticAndClassMethodsAreRejectedBySymbolParser() {
        let discovery = TestDiscovery()
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "static M.C.testStaticHelper() -> ()", moduleName: "M"),
                     "static test-prefixed helpers must never become scheduled tests")
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "class M.C.testClassHelper() -> ()", moduleName: "M"))
        XCTAssertNil(discovery.testIdentifier(fromDemangled: "@objc static M.C.testStaticObjC() -> ()", moduleName: "M"))
        // Instance methods still pass.
        XCTAssertEqual(discovery.testIdentifier(fromDemangled: "M.C.testReal() throws -> ()", moduleName: "M"), "M/C/testReal()")
    }

    // MARK: - Platform derivation

    func testPlatformDerivation() {
        XCTAssertEqual(TestPlatform.derive(testHostPath: "__TESTROOT__/Debug-iphonesimulator/X-Runner.app", dyldPaths: ""), .simulator)
        XCTAssertEqual(TestPlatform.derive(testHostPath: "__TESTROOT__/Debug-iphoneos/X-Runner.app", dyldPaths: ""), .device)
        XCTAssertEqual(TestPlatform.derive(testHostPath: "__TESTROOT__/Debug/X-Runner.app",
                                           dyldPaths: "__PLATFORMS__/MacOSX.platform/Developer/Library"), .macOS)
        XCTAssertNil(TestPlatform.derive(testHostPath: "somewhere/strange", dyldPaths: ""))
    }
}
