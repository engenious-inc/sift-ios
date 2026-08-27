import Foundation

/// Side-effect-free test discovery: reads XCTest symbols out of built test-bundle
/// binaries with nm + swift-demangle. Requires nothing but the built products —
/// no simulators, no SSH, no build zipping.
public struct TestDiscovery: Sendable {

    private let log: Logging?

    public init(log: Logging? = nil) {
        self.log = log
    }

    /// All tests in the xctestrun's bundles, as canonical "Module/Class/test()" names.
    /// A bundle whose binary cannot be enumerated fails discovery outright —
    /// silently skipping it would let part of the suite vanish behind exit 0.
    public func tests(xctestrun: XCTestRun, configuration: String?) async throws -> [String] {
        var allTests: [String] = []
        var failures: [String] = []
        for bundle in xctestrun.testBundleExecPaths(config: configuration) {
            do {
                let tests = try await dump(binaryPath: bundle.path, moduleName: bundle.target)
                log?.message("\(bundle.target): \(tests.count) tests")
                allTests.append(contentsOf: tests)
            } catch {
                failures.append("\(bundle.target): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw NSError(
                domain: "Test discovery failed for \(failures.count) bundle(s):\n" + failures.joined(separator: "\n"),
                code: 1
            )
        }
        return allTests
    }

    /// Extracts "Module/Class/testMethod()" identifiers from one binary.
    func dump(binaryPath: String, moduleName: String) async throws -> [String] {
        let shell = Run()
        let nm = try await shell.runChecked("/usr/bin/nm", ["-gU", binaryPath])
        let symbols = nm.stdout
            .components(separatedBy: "\n")
            .compactMap { $0.components(separatedBy: " ").last }
            .filter { $0.hasPrefix("_$s") || $0.hasPrefix("_T0") || $0.hasPrefix("$s") }

        guard !symbols.isEmpty else { return [] }

        var tests: [String] = []
        // Demangle in batches to stay under argv limits for large bundles.
        for batch in stride(from: 0, to: symbols.count, by: 2000).map({ Array(symbols[$0..<min($0 + 2000, symbols.count)]) }) {
            let demangled = try await shell.runChecked("/usr/bin/xcrun", ["swift-demangle", "-compact"] + batch)
            for line in demangled.stdout.components(separatedBy: "\n") {
                guard let identifier = testIdentifier(fromDemangled: line, moduleName: moduleName) else { continue }
                tests.append(identifier)
            }
        }
        return TestName.canonicalList(tests)
    }

    /// Matches "Module.Class.testSomething() -> ()" and variants; XCTest discovers
    /// zero-argument instance methods prefixed "test". Internal for unit testing.
    func testIdentifier(fromDemangled line: String, moduleName: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Expected shapes: "Module.Class.testFoo() -> ()", "Module.Class.testFoo()",
        // possibly "@objc Module.Class.testFoo() -> ()".
        guard trimmed.contains("()") else { return nil }
        var signature = trimmed
        if let arrowRange = signature.range(of: " -> ") {
            signature = String(signature[..<arrowRange.lowerBound])
        }
        for prefix in ["@objc ", "static "] where signature.hasPrefix(prefix) {
            signature = String(signature.dropFirst(prefix.count))
        }
        // "test() throws", "test() async", "test() async throws"
        for suffix in [" throws", " async"] {
            while signature.hasSuffix(suffix) {
                signature = String(signature.dropLast(suffix.count))
            }
        }
        guard signature.hasSuffix("()") else { return nil }
        let name = String(signature.dropLast(2))
        let components = name.components(separatedBy: ".")
        // Module.Class.testMethod (allow nested classes: >= 3 components)
        guard components.count >= 3, let method = components.last, method.hasPrefix("test") else { return nil }
        guard components.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        // The mangled module name can differ from the bundle name — use the bundle's.
        let classPath = components.dropFirst().dropLast().joined(separator: "/")
        return "\(moduleName)/\(classPath)/\(method)()"
    }
}
