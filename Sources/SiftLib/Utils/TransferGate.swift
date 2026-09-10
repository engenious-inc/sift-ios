import Foundation

/// Bounds how many nodes stream the build archive at once (config
/// `maxConcurrentUploads`; nil = unlimited, the historical behavior).
///
/// Every upload keeps one controller thread blocked in libssh2 and shares one
/// uplink with every other upload: N parallel transfers finish together at
/// ~N× the single-transfer time, so no node can start testing early. A cap lets
/// the first nodes finish (and start running tests) while the rest wait.
/// Permits are handed to waiters FIFO; a waiter whose task is cancelled leaves
/// the queue with `CancellationError` and never consumes a permit.
final class TransferGate: @unchecked Sendable {
    private let limit: Int?
    private let lock = NSLock()
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int?) {
        self.limit = limit
    }

    /// Permits currently held — observable for tests.
    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inUse
    }

    /// Tasks queued for a permit — observable for tests.
    var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// Runs `body` while holding a permit. The permit is released whether the
    /// body returns or throws. A task that is already cancelled, or is cancelled
    /// while WAITING, throws `CancellationError` before the body ever runs —
    /// capped or not, a cancelled run must never start a new upload.
    func withPermit<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        // Handoff window: `release()` dequeues the next waiter and THEN resumes it;
        // a cancellation landing in between finds no waiter to evict, so acquire()
        // returns normally to a cancelled task. Re-check here (the defer returns
        // the permit) so a cancelled node never starts connecting.
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        guard let limit else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // The cancellation handler may already have run (a task cancelled
                // before reaching this point finds no waiter to evict). Deciding
                // under the lock means a handler racing this registration either
                // sees the waiter or the waiter sees the cancellation flag.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if inUse < limit && waiters.isEmpty {
                    inUse += 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let evicted = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            evicted?.continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        guard limit != nil else { return }
        lock.lock()
        if waiters.isEmpty {
            inUse -= 1
            lock.unlock()
            return
        }
        // Hand the permit straight to the next waiter — `inUse` is unchanged.
        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }
}
