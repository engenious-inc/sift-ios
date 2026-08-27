import Foundation

/// Master-side result ingestion: unzips downloaded result archives, moves the
/// xcresult bundles into the final directory, and extracts per-test outcomes.
actor ResultCollector {

    private let workspace: RunWorkspace
    private let tool: XCResultTool
    private let log: Logging?
    private var collectedResultPaths: [String] = []

    init(workspace: RunWorkspace, tool: XCResultTool = XCResultTool(), log: Logging?) {
        self.workspace = workspace
        self.tool = tool
        self.log = log
    }

    /// Ingests one downloaded zip containing one xcresult bundle.
    /// Returns the outcomes parsed from it.
    func ingest(zipPath: String) async throws -> [TestOutcome] {
        let unzipID = UUID().uuidString
        let unzipDirectory = "\(workspace.workPath)/unzip/\(unzipID)"
        defer {
            try? FileManager.default.removeItem(atPath: unzipDirectory)
            try? FileManager.default.removeItem(atPath: zipPath)
        }
        try FileManager.default.createDirectory(atPath: unzipDirectory, withIntermediateDirectories: true)
        try await Run().runChecked("/usr/bin/unzip", ["-o", "-q", zipPath, "-d", unzipDirectory])

        let entries = try FileManager.default.contentsOfDirectory(atPath: unzipDirectory)
        let xcresults = entries.filter { $0.hasSuffix(".xcresult") }
        guard !xcresults.isEmpty else {
            throw NSError(domain: "no .xcresult found in downloaded archive \(zipPath)", code: 1)
        }

        var outcomes: [TestOutcome] = []
        for name in xcresults {
            let finalPath = "\(workspace.finalPath)/\(unzipID)-\(name)"
            try FileManager.default.moveItem(atPath: "\(unzipDirectory)/\(name)", toPath: finalPath)
            collectedResultPaths.append(finalPath)
            outcomes.append(contentsOf: try await tool.testOutcomes(xcresultPath: finalPath))
        }
        return outcomes
    }

    /// Merges every collected bundle into final_result.xcresult. Throws on failure —
    /// a missing merged artifact must fail the run, not log-and-continue.
    func mergeAll() async throws -> String? {
        guard !collectedResultPaths.isEmpty else {
            log?.warning("No test results were collected — nothing to merge")
            return nil
        }
        let mergedPath = "\(workspace.finalPath)/final_result.xcresult"
        try await tool.merge(inputPaths: collectedResultPaths, outputPath: mergedPath)
        // The per-chunk bundles are folded into the merged bundle; drop them.
        for path in collectedResultPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        log?.message(verboseMsg: "Merged \(collectedResultPaths.count) result bundles into \(mergedPath)")
        return mergedPath
    }
}
