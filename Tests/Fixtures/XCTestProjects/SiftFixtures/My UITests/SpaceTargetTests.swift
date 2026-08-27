import XCTest

/// Lives in a target whose name contains a space ("My UITests") while its
/// ProductModuleName is underscored ("My_UITests") — the exact shape that
/// breaks any tool confusing the two namespaces.
final class SpaceTargetTests: XCTestCase {

    func testInSpaceTarget() {
        XCTAssertTrue(true)
    }

    func testAnotherInSpaceTarget() {
        XCTAssertEqual(2 + 2, 4)
    }

    /// A static helper with a `test` prefix: XCTest never runs it, and discovery
    /// must never schedule it (the historical phantom-test bug).
    static func testStaticHelper() -> Bool { true }
}
