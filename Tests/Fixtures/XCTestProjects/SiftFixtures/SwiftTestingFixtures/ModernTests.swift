import Testing

/// Pure Swift Testing (no XCTest): invisible to nm-based discovery, first-class
/// for `-enumerate-tests` and xcresult parsing.
@Test func modernAdditionWorks() {
    #expect(1 + 1 == 2)
}

@Suite struct ModernSuite {
    @Test func suiteCaseWorks() {
        #expect("sift".count == 4)
    }
}
