@import XCTest;

/// Pure Objective-C XCTest class: invisible to Swift-symbol discovery, visible
/// to `xcodebuild -enumerate-tests`.
@interface LegacyObjCTests : XCTestCase
@end

@implementation LegacyObjCTests

- (void)testObjCStyleAssertion {
    XCTAssertTrue(YES);
}

- (void)testSecondObjC {
    XCTAssertEqual(1 + 1, 2);
}

@end
