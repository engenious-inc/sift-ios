import Foundation

/// Result-bundle parsing/merging seam — injected through the node factory so
/// behavioral tests can fake it.
protocol XCResultParsing: Sendable {
    func testOutcomes(xcresultPath: String) async throws -> [TestOutcome]
    @discardableResult
    func merge(inputPaths: [String], outputPath: String) async throws -> Bool
}

/// Wrapper around the modern `xcresulttool get test-results` API (Xcode 16+).
/// The legacy `--legacy` object-graph API is deprecated for removal and is not used.
struct XCResultTool: XCResultParsing, Sendable {

    // MARK: - Modern test-results models

    struct TestResultsDocument: Codable {
        let testNodes: [TestNode]
    }

    struct TestNode: Codable {
        let nodeType: String
        let name: String
        let result: String?
        let durationInSeconds: Double?
        let nodeIdentifier: String?
        let children: [TestNode]?
    }

    /// Extracts per-test outcomes from an xcresult bundle.
    /// Identifiers are Sift-canonical: "<bundle>/<Class>/<testMethod>()".
    func testOutcomes(xcresultPath: String) async throws -> [TestOutcome] {
        let result = try await Run().runChecked(
            "/usr/bin/xcrun",
            ["xcresulttool", "get", "test-results", "tests", "--path", xcresultPath],
            onCancellation: .runToCompletion, timeout: 600
        )
        guard let jsonData = result.stdout.data(using: .utf8) else {
            throw NSError(domain: "xcresulttool returned undecodable output for \(xcresultPath)", code: 1)
        }
        return try Self.outcomes(fromTestResultsJSON: jsonData)
    }

    /// Pure parsing entry, shared with the unit tests so they exercise the
    /// production traversal rather than a reimplementation.
    static func outcomes(fromTestResultsJSON jsonData: Data) throws -> [TestOutcome] {
        let document = try JSONDecoder().decode(TestResultsDocument.self, from: jsonData)
        let tool = XCResultTool()
        var outcomes: [TestOutcome] = []
        for planNode in document.testNodes {
            tool.collectOutcomes(node: planNode, bundleName: nil, into: &outcomes)
        }
        return outcomes
    }

    private func collectOutcomes(node: TestNode, bundleName: String?, into outcomes: inout [TestOutcome]) {
        var bundleName = bundleName
        if node.nodeType.hasSuffix("test bundle") {
            bundleName = node.name
        }
        if node.nodeType == "Test Case" {
            guard let identifier = node.nodeIdentifier, let bundleName else { return }
            let canonicalName = TestName.canonical("\(bundleName)/\(identifier)")
            let message = failureMessages(of: node).joined(separator: "\n")
            let kind: TestOutcome.Kind
            switch node.result {
            case "Passed", "Expected Failure":
                kind = .pass
            case "Skipped":
                kind = .skipped
            case "Failed":
                kind = .failed
            default:
                // A verdict we don't recognize is not a verdict.
                kind = .notExecuted
            }
            outcomes.append(TestOutcome(
                test: canonicalName,
                kind: kind,
                duration: node.durationInSeconds ?? 0,
                message: message
            ))
            return
        }
        for child in node.children ?? [] {
            collectOutcomes(node: child, bundleName: bundleName, into: &outcomes)
        }
    }

    private func failureMessages(of node: TestNode) -> [String] {
        var messages: [String] = []
        for child in node.children ?? [] {
            if child.nodeType == "Failure Message" {
                messages.append(child.name)
            }
            messages.append(contentsOf: failureMessages(of: child))
        }
        return messages
    }

    // MARK: - Merge

    @discardableResult
    func merge(inputPaths: [String], outputPath: String) async throws -> Bool {
        guard !inputPaths.isEmpty else { return false }
        if inputPaths.count == 1 {
            // Copy, not move — never destroy the source bundle.
            try await Run().runChecked(
                "/bin/cp", ["-R", inputPaths[0], outputPath],
                onCancellation: .runToCompletion, timeout: 600
            )
            return true
        }
        try await Run().runChecked(
            "/usr/bin/xcrun",
            ["xcresulttool", "merge"] + inputPaths + ["--output-path", outputPath],
            onCancellation: .runToCompletion, timeout: 900
        )
        return true
    }
}
