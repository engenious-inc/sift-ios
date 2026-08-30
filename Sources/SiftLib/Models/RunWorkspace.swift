import Foundation

/// Run-scoped directory layout. Everything a run produces is STAGED under a unique
/// per-run directory (0700) and published to `final/` only by an atomic rename at the
/// end — a failed or dying run can never destroy the previous `final/`, and two runs
/// sharing an output directory are serialized by an advisory lock.
public struct RunWorkspace: Sendable {
    public let runID: String
    public let outputDirectoryPath: String

    /// Internally generated run identity — always a safe single path component.
    public init(outputDirectoryPath: String) {
        self.outputDirectoryPath = outputDirectoryPath
        self.runID = UUID().uuidString
    }

    /// Caller-supplied run identity: strictly one safe path component, or an error —
    /// a separator or dot-component would let cleanup escape the run directory.
    public init(outputDirectoryPath: String, runID: String) throws {
        guard Self.isSafePathComponent(runID) else {
            throw XCTestRunError("runID must be a single path component (got '\(runID)')")
        }
        self.outputDirectoryPath = outputDirectoryPath
        self.runID = runID
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    /// Local scratch directory for this run (zips, unzipped results, process bookkeeping).
    public var workPath: String { "\(outputDirectoryPath)/.sift/runs/\(runID)" }

    /// Where this run's artifacts are STAGED (reports, per-chunk bundles, merged
    /// xcresult). Becomes `final/` atomically at publication.
    public var stagingPath: String { "\(workPath)/staging" }

    /// Stable location CI consumers read. Only ever replaced by a completed rename.
    public var finalPath: String { "\(outputDirectoryPath)/final" }

    /// Remote scratch directory for this run on a node. `nodeSlug` isolates node
    /// entries that share a host + deploymentPath — they must never share upload,
    /// results, DerivedData, or process directories.
    public func remoteWorkPath(deploymentPath: String, nodeSlug: String) -> String {
        "\(deploymentPath)/.sift/runs/\(runID)/\(nodeSlug)"
    }

    /// Sanitizes a node name into a safe remote path component.
    public static func nodeSlug(for nodeName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = nodeName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let slug = String(mapped)
        return Self.isSafePathComponent(slug) ? slug : "node"
    }

    public func prepareLocal() throws {
        let fm = FileManager.default
        // 0700 the whole run-private chain; `final/` is NOT touched here.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(atPath: "\(outputDirectoryPath)/.sift", withIntermediateDirectories: true, attributes: ownerOnly)
        try fm.createDirectory(atPath: workPath, withIntermediateDirectories: true, attributes: ownerOnly)
        try fm.createDirectory(atPath: stagingPath, withIntermediateDirectories: true, attributes: ownerOnly)
    }

    /// Atomically publishes the staged artifacts as `final/`. There is NO instant at
    /// which `final/` is absent: an existing `final/` is exchanged with staging in a
    /// single `renameatx_np(RENAME_SWAP)` syscall (SIGKILL at any point leaves either
    /// the old or the new directory in place); a first publish is one plain rename.
    /// Returns the published path.
    @discardableResult
    public func publish() throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: finalPath) else {
            try fm.moveItem(atPath: stagingPath, toPath: finalPath)
            return finalPath
        }
        if renameatx_np(AT_FDCWD, stagingPath, AT_FDCWD, finalPath, UInt32(RENAME_SWAP)) == 0 {
            // The previous final now sits at the staging path — run-private scratch,
            // removed here (or with the run directory by cleanupLocal).
            try? fm.removeItem(atPath: stagingPath)
            return finalPath
        }
        // Filesystem without atomic exchange (e.g. NFS/SMB): NEVER fall back to a
        // two-move replace — a crash between the moves would leave no `final/` at
        // all, and on a network filesystem that window is not small. Park the new
        // results at a sibling path (single rename) and fail loudly: the previous
        // `final/` is untouched, nothing is lost, and the error names both paths.
        let swapErrno = errno
        let parkedPath = "\(outputDirectoryPath)/final-incoming-\(runID)"
        try? fm.removeItem(atPath: parkedPath)
        try fm.moveItem(atPath: stagingPath, toPath: parkedPath)
        throw XCTestRunError(
            "this filesystem does not support atomically replacing \(finalPath) "
            + "(renameatx_np: \(String(cString: strerror(swapErrno)))) — the previous final/ was preserved and "
            + "this run's complete results were parked at \(parkedPath); move them into place manually, "
            + "or point outputDirectoryPath at a local (APFS/HFS+) volume"
        )
    }

    /// Removes the run-private scratch directory. A failure is reported (the
    /// caller decides whether it becomes a health event) — never swallowed.
    @discardableResult
    public func cleanupLocal() -> Error? {
        do {
            try FileManager.default.removeItem(atPath: workPath)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Output-directory lock

    /// Advisory exclusive lock on the output directory, auto-released if the process
    /// dies (flock semantics). `release()` (or deinit) unlocks.
    public final class RunLock: @unchecked Sendable {
        private var descriptor: Int32
        private let path: String

        fileprivate init(descriptor: Int32, path: String) {
            self.descriptor = descriptor
            self.path = path
        }

        public func release() {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }

        deinit { release() }

        fileprivate static func owner(atPath path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        }
    }

    /// Takes the exclusive output-directory lock or throws naming the current owner.
    public func acquireLock() throws -> RunLock {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(outputDirectoryPath)/.sift", withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let lockPath = "\(outputDirectoryPath)/.sift/lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw XCTestRunError("cannot open output-directory lock at \(lockPath): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let owner = RunLock.owner(atPath: lockPath)
            close(descriptor)
            throw XCTestRunError(
                "another Sift run (\(owner)) owns the output directory \(outputDirectoryPath) — "
                + "wait for it to finish or use a different outputDirectoryPath"
            )
        }
        // Record the owner for the error message of whoever loses the race.
        ftruncate(descriptor, 0)
        let identity = "pid \(ProcessInfo.processInfo.processIdentifier), run \(runID)"
        _ = identity.withCString { write(descriptor, $0, strlen($0)) }
        return RunLock(descriptor: descriptor, path: lockPath)
    }
}
