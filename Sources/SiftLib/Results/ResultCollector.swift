import Foundation

/// Master-side result ingestion: unzips downloaded result archives, moves the
/// xcresult bundles into the staging directory, and extracts per-test outcomes.
actor ResultCollector {

    private let workspace: RunWorkspace
    private let tool: XCResultParsing
    private let log: Logging?
    private var collectedResultPaths: [String] = []
    private var retainedDiagnostics: [String] = []
    private var mergeSucceeded: Bool?

    init(workspace: RunWorkspace, tool: XCResultParsing = XCResultTool(), log: Logging?) {
        self.workspace = workspace
        self.tool = tool
        self.log = log
    }

    /// Ingests one downloaded zip of xcresult bundle(s), TRANSACTIONALLY: every
    /// bundle parses before any is committed to the merge set. A failing archive is
    /// RETAINED under diagnostics/failed-ingest with a sidecar error file — corrupt
    /// evidence is kept for post-mortems, never destroyed.
    func ingest(zipPath: String) async throws -> [TestOutcome] {
        do {
            return try await ingestOrThrow(zipPath: zipPath)
        } catch {
            let diagnosticsDirectory = "\(workspace.stagingPath)/diagnostics/failed-ingest"
            let name = (zipPath as NSString).lastPathComponent
            try? FileManager.default.createDirectory(atPath: diagnosticsDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let retainedPath = "\(diagnosticsDirectory)/\(name)"
            try? FileManager.default.moveItem(atPath: zipPath, toPath: retainedPath)
            try? "\(error)".write(toFile: retainedPath + ".error.txt", atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: retainedPath) {
                retainedDiagnostics.append(retainedPath)
                log?.warning("result archive could not be ingested — retained at \(retainedPath)")
            }
            throw error
        }
    }

    private func ingestOrThrow(zipPath: String) async throws -> [TestOutcome] {
        let unzipID = UUID().uuidString
        let unzipDirectory = "\(workspace.workPath)/unzip/\(unzipID)"
        defer { try? FileManager.default.removeItem(atPath: unzipDirectory) }
        try FileManager.default.createDirectory(atPath: unzipDirectory, withIntermediateDirectories: true)
        // Salvage semantics: after Ctrl-C this unzip IS the partial report — it must
        // finish despite cancellation, bounded so a hang can never wedge shutdown.
        try await Run().runChecked(
            "/usr/bin/unzip", ["-o", "-q", zipPath, "-d", unzipDirectory],
            onCancellation: .runToCompletion, timeout: 600
        )

        let entries = try FileManager.default.contentsOfDirectory(atPath: unzipDirectory)
        let xcresults = entries.filter { $0.hasSuffix(".xcresult") }
        guard !xcresults.isEmpty else {
            throw NSError(domain: "no .xcresult found in downloaded archive \(zipPath)", code: 1)
        }
        for stray in entries where !stray.hasSuffix(".xcresult") {
            log?.warning("unexpected entry '\(stray)' in result archive — ignored")
        }

        // Pass 1: parse EVERY bundle (a corrupted one aborts the whole archive
        // before anything reaches the merge set).
        var parsed: [(name: String, path: String, outcomes: [TestOutcome])] = []
        for name in xcresults {
            let unzippedPath = "\(unzipDirectory)/\(name)"
            let bundleOutcomes = try await tool.testOutcomes(xcresultPath: unzippedPath)
            parsed.append((name, unzippedPath, bundleOutcomes))
        }
        // Pass 2: commit.
        var outcomes: [TestOutcome] = []
        for bundle in parsed {
            let stagedPath = "\(workspace.stagingPath)/\(unzipID)-\(bundle.name)"
            try FileManager.default.moveItem(atPath: bundle.path, toPath: stagedPath)
            collectedResultPaths.append(stagedPath)
            outcomes.append(contentsOf: bundle.outcomes)
        }
        try? FileManager.default.removeItem(atPath: zipPath)
        return outcomes
    }

    /// Merges every collected bundle into final_result.xcresult. On failure the
    /// per-chunk bundles are KEPT in staging (published as raw evidence).
    func mergeAll() async throws -> String? {
        guard !collectedResultPaths.isEmpty else {
            log?.warning("No test results were collected — nothing to merge")
            mergeSucceeded = nil
            return nil
        }
        let mergedPath = "\(workspace.stagingPath)/final_result.xcresult"
        do {
            try await tool.merge(inputPaths: collectedResultPaths, outputPath: mergedPath)
        } catch {
            mergeSucceeded = false
            throw error
        }
        mergeSucceeded = true
        // The per-chunk bundles are folded into the merged bundle; drop them.
        for path in collectedResultPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        log?.message(verboseMsg: "Merged \(collectedResultPaths.count) result bundles into \(mergedPath)")
        return mergedPath
    }

    /// Test seam: seeds a collected path without running ingest (used to exercise
    /// the merge-failure path against non-parsable inputs).
    func recordCollected(path: String) {
        collectedResultPaths.append(path)
    }

    /// Paths (still under staging) retained for post-mortems: failed-ingest archives,
    /// and — after a failed merge — the raw per-chunk bundles.
    func retainedArtifacts() -> [String] {
        var artifacts = retainedDiagnostics
        if mergeSucceeded == false {
            artifacts.append(contentsOf: collectedResultPaths)
        }
        return artifacts
    }
}
