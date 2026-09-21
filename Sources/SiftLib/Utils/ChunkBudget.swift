import Foundation

/// Wall-clock budget for one `xcodebuild` chunk, DERIVED from the per-test
/// allowance instead of equal to it.
///
/// `testsExecutionTimeout` is injected into the xctestrun as XCTest's per-test
/// execution time allowance. XCTest starts that clock when each test starts,
/// rounds the value UP to whole minutes, and on expiry fails the test, restarts
/// the runner and carries on — normally leaving a readable bundle with the verdict
/// recorded. Sift's chunk clock starts earlier (at xcodebuild launch) and spans
/// every leased test in sequence, so a chunk deadline equal to the raw allowance
/// always pre-empted XCTest: a test that legitimately finished near its allowance
/// had its chunk TERM/KILL-ed during the runner restart or bundle finalization,
/// the bundle was never finalized, and a real verdict was lost as "not executed"
/// (with the executor blamed for an infrastructure failure). The derived budget
/// leaves room for every leased test to use its whole effective allowance plus
/// per-test and per-chunk overheads, so that in the normal case XCTest's own
/// timeout fires first and the destructive kill is left for an xcodebuild that
/// XCTest could not unstick. It is a conservative estimate, not a guarantee:
/// overheads that outgrow it (a slow device install, repeated runner restarts)
/// still end in a kill, and the budget is capped at `maximumSeconds`.
struct ChunkBudget: Sendable, Equatable {

    /// Per-test allowance in seconds, exactly as injected into the xctestrun.
    let perTestAllowance: Int
    /// Headroom shared by the whole chunk: xcodebuild startup (app/runner install
    /// and launch on a device) and result-bundle finalization.
    var fixedOverhead: Int = 300
    /// Headroom per leased test: a runner restart after a crash or an XCTest
    /// timeout, diagnostics capture, teardown.
    var perTestOverhead: Int = 60

    /// Ceiling on any budget (10 years): keeps `Duration`/clock arithmetic far
    /// from overflow whatever the config says. A whole number of minutes.
    static let maximumSeconds = 315_360_000

    /// The allowance XCTest actually enforces for a configured value: rounded UP
    /// to whole minutes (Apple: "The test rounds up the value you supply to the
    /// nearest minute").
    static func effectiveAllowance(_ seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        let clamped = min(seconds, maximumSeconds)
        return (clamped + 59) / 60 * 60
    }

    /// Budget for a chunk of `testCount` leased tests:
    /// `fixedOverhead + testCount × (effectiveAllowance + perTestOverhead)`,
    /// saturating at `maximumSeconds`.
    func seconds(testCount: Int) -> Int {
        compute(testCount: testCount).seconds
    }

    /// Human-readable breakdown for logs, e.g. `780s = 300 + 1 × (420 + 60)`. A
    /// saturated budget says so instead of printing a false equality.
    func describe(testCount: Int) -> String {
        let result = compute(testCount: testCount)
        let formula = "\(Self.clamp(fixedOverhead)) + \(max(0, testCount)) × "
            + "(\(Self.effectiveAllowance(perTestAllowance)) + \(Self.clamp(perTestOverhead)))"
        // The formula shows CLAMPED inputs, so under an input-only cap it equals
        // the ceiling rather than exceeding it — the wording covers both cases.
        return result.capped
            ? "\(result.seconds)s (\(Self.maximumSeconds)s ceiling applied to inputs or total; formula \(formula))"
            : "\(result.seconds)s = \(formula)"
    }

    private func compute(testCount: Int) -> (seconds: Int, capped: Bool) {
        let inputCapped = perTestAllowance > Self.maximumSeconds
            || fixedOverhead > Self.maximumSeconds || perTestOverhead > Self.maximumSeconds
        let perTest = Self.effectiveAllowance(perTestAllowance) + Self.clamp(perTestOverhead)
        let (scaled, overflow) = perTest.multipliedReportingOverflow(by: max(0, testCount))
        let allTests = overflow ? Self.maximumSeconds : min(scaled, Self.maximumSeconds)
        let total = Self.clamp(fixedOverhead) + allTests
        let capped = inputCapped || overflow || scaled > Self.maximumSeconds || total > Self.maximumSeconds
        return (min(total, Self.maximumSeconds), capped)
    }

    private static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, 0), maximumSeconds)
    }
}
