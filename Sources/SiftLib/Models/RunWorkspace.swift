import Foundation

/// Run-scoped directory layout. All temporary artifacts live under a unique per-run
/// directory so cleanup can never touch anything Sift did not create.
public struct RunWorkspace: Sendable {
    public let runID: String
    public let outputDirectoryPath: String

    public init(outputDirectoryPath: String, runID: String = UUID().uuidString) {
        self.outputDirectoryPath = outputDirectoryPath
        self.runID = runID
    }

    /// Local scratch directory for this run (zips, unzipped results, process bookkeeping).
    public var workPath: String { "\(outputDirectoryPath)/.sift/runs/\(runID)" }

    /// Final artifacts directory (merged xcresult, reports). Kept stable for CI consumers.
    public var finalPath: String { "\(outputDirectoryPath)/final" }

    /// Remote scratch directory for this run on a node.
    public func remoteWorkPath(deploymentPath: String) -> String {
        "\(deploymentPath)/.sift/runs/\(runID)"
    }

    public func prepareLocal() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: workPath, withIntermediateDirectories: true)
        // Replace only the final directory — never sibling content of outputDirectoryPath.
        if fm.fileExists(atPath: finalPath) {
            try fm.removeItem(atPath: finalPath)
        }
        try fm.createDirectory(atPath: finalPath, withIntermediateDirectories: true)
    }

    public func cleanupLocal() {
        try? FileManager.default.removeItem(atPath: workPath)
    }
}
