import XCTest
@testable import SiftLib

/// Upload fan-out cap (config `maxConcurrentUploads`): bounded concurrency,
/// FIFO hand-over, and cancellation that never leaks or consumes a permit.
final class TransferGateTests: XCTestCase {

    private actor Tracker {
        private(set) var inFlight = 0
        private(set) var peak = 0
        private(set) var completed = 0
        func enter() { inFlight += 1; peak = max(peak, inFlight) }
        func exit() { inFlight -= 1; completed += 1 }
    }

    private actor Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func fire() {
            fired = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        func raise() { lock.lock(); raised = true; lock.unlock() }
    }

    func testUnlimitedGateNeverWaitsAndHoldsNothing() async throws {
        let gate = TransferGate(limit: nil)
        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testCapBoundsConcurrencyAndEveryWaiterIsServed() async throws {
        let gate = TransferGate(limit: 2)
        let tracker = Tracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.withPermit {
                        await tracker.enter()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        await tracker.exit()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await tracker.peak
        let completed = await tracker.completed
        XCTAssertEqual(completed, 6)
        XCTAssertLessThanOrEqual(peak, 2, "more uploads in flight than the cap allows")
        XCTAssertEqual(peak, 2, "the cap should be fully used when enough work is queued")
        XCTAssertEqual(gate.activeCount, 0, "every permit must be returned")
    }

    func testPermitIsReleasedWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let gate = TransferGate(limit: 1)
        do {
            try await gate.withPermit { throw Boom() }
            XCTFail("expected the body's error to propagate")
        } catch is Boom {}
        XCTAssertEqual(gate.activeCount, 0)
        let after = try await gate.withPermit { "ok" }
        XCTAssertEqual(after, "ok")
    }

    func testCancelledWaiterLeavesWithoutRunningOrConsumingAPermit() async throws {
        let gate = TransferGate(limit: 1)
        let holderInside = Signal()
        let releaseHolder = Signal()
        let holder = Task {
            try await gate.withPermit {
                await holderInside.fire()
                await releaseHolder.wait()
            }
        }
        await holderInside.wait()
        XCTAssertEqual(gate.activeCount, 1)

        let bodyRan = Flag()
        let waiter = Task {
            try await gate.withPermit { bodyRan.raise() }
        }
        // Cancel only once the waiter is provably queued behind the holder — this
        // must exercise eviction from the queue, not the pre-registration check.
        try await Self.waitUntil { gate.waitingCount == 1 }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must throw, not run")
        } catch is CancellationError {}
        XCTAssertFalse(bodyRan.value, "the cancelled waiter's body must never run")
        XCTAssertEqual(gate.activeCount, 1, "the holder still owns the only permit")

        await releaseHolder.fire()
        try await holder.value
        XCTAssertEqual(gate.activeCount, 0, "the evicted waiter must not have consumed the permit")
        let late = try await gate.withPermit { "served" }
        XCTAssertEqual(late, "served")
    }

    func testTaskCancelledBeforeAcquiringNeverRunsTheBodyEvenWithAFreePermit() async throws {
        for limit in [Int?.some(1), nil] {
            let gate = TransferGate(limit: limit)
            let proceed = Signal()
            let bodyRan = Flag()
            let task = Task {
                await proceed.wait()               // not cancellable: the flag is set while parked here
                try await gate.withPermit { bodyRan.raise() }
            }
            task.cancel()
            await proceed.fire()
            do {
                try await task.value
                XCTFail("an already-cancelled task must not start an upload (limit \(String(describing: limit)))")
            } catch is CancellationError {}
            XCTAssertFalse(bodyRan.value)
            XCTAssertEqual(gate.activeCount, 0)
            XCTAssertEqual(gate.waitingCount, 0)
        }
    }

    /// Polls `condition` every 10 ms; fails the test if it never becomes true.
    static func waitUntil(timeoutSeconds: Double = 5, _ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeoutSeconds)s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
