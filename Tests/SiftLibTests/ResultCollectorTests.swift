import XCTest
@testable import SiftLib

/// Phase 5: transactional ingestion, forensic retention, and merge-failure behavior.
final class ResultCollectorTests: XCTestCase {

    private func makeWorkspace() throws -> RunWorkspace {
        let base = NSTemporaryDirectory() + "sift-collector-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }
        let workspace = RunWorkspace(outputDirectoryPath: base)
        try workspace.prepareLocal()
        return workspace
    }

    private func makeZip(named zipName: String, containing entries: [String: String], workspace: RunWorkspace) throws -> String {
        let sourceDirectory = "\(workspace.workPath)/zipsrc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sourceDirectory, withIntermediateDirectories: true)
        for (path, content) in entries {
            let full = "\(sourceDirectory)/\(path)"
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
        }
        let zipPath = "\(workspace.workPath)/\(zipName)"
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = URL(fileURLWithPath: sourceDirectory)
        zip.arguments = ["-r", "-q", zipPath] + entries.keys.map { $0.components(separatedBy: "/").first! }.uniqued()
        try zip.run(); zip.waitUntilExit()
        return zipPath
    }

    func testUnparsableArchiveIsRetainedWithErrorSidecar() async throws {
        let workspace = try makeWorkspace()
        // A "bundle" xcresulttool cannot parse.
        let zipPath = try makeZip(named: "bad.zip",
                                  containing: ["Garbage.xcresult/Info.plist": "not a real bundle"],
                                  workspace: workspace)
        let collector = ResultCollector(workspace: workspace, log: nil)
        do {
            _ = try await collector.ingest(zipPath: zipPath)
            XCTFail("expected ingest to throw")
        } catch {
            let retained = "\(workspace.stagingPath)/diagnostics/failed-ingest/bad.zip"
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained), "evidence must be retained")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained + ".error.txt"))
            let artifacts = await collector.retainedArtifacts()
            XCTAssertEqual(artifacts, [retained])
        }
    }

    func testArchiveWithoutBundlesIsRetainedAndNothingCommitted() async throws {
        let workspace = try makeWorkspace()
        let zipPath = try makeZip(named: "empty.zip", containing: ["readme/notes.txt": "hi"], workspace: workspace)
        let collector = ResultCollector(workspace: workspace, log: nil)
        do {
            _ = try await collector.ingest(zipPath: zipPath)
            XCTFail("expected ingest to throw")
        } catch {
            // Nothing reached the merge set; the merge then reports nothing to merge.
            let merged = try await collector.mergeAll()
            XCTAssertNil(merged)
        }
    }

    func testFailedMergeRetainsRawBundlesForPublication() async throws {
        let workspace = try makeWorkspace()
        let collector = ResultCollector(workspace: workspace, log: nil)
        // Two seeded garbage "bundles": xcresulttool merge must fail, and both paths
        // must be reported as retained evidence (Controller publishes them).
        for name in ["a.xcresult", "b.xcresult"] {
            let path = "\(workspace.stagingPath)/\(name)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try "junk".write(toFile: "\(path)/Info.plist", atomically: true, encoding: .utf8)
            await collector.recordCollected(path: path)
        }
        do {
            _ = try await collector.mergeAll()
            XCTFail("expected merge of garbage bundles to throw")
        } catch {
            let artifacts = await collector.retainedArtifacts()
            XCTAssertEqual(artifacts.count, 2)
            for artifact in artifacts {
                XCTAssertTrue(FileManager.default.fileExists(atPath: artifact), "raw bundles kept: \(artifact)")
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
