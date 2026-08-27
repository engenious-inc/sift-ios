import Foundation

/// How tests are discovered from built products.
public enum DiscoveryBackend: String, Sendable, CaseIterable {
    /// `xcodebuild -enumerate-tests` (default): Xcode's own view of the bundles.
    /// Sees Objective-C and Swift Testing, respects test-plan enablement, and can
    /// never invent a phantom test.
    case enumeration
    /// Legacy `nm` + `swift-demangle` symbol scan. Swift XCTest only. Kept for one
    /// transitional release behind an explicit `--discovery symbols`; never an
    /// automatic fallback.
    case symbols
}

/// Test discovery from built products — no SSH, no remote nodes.
/// All identifiers are emitted in the canonical BUNDLE-name namespace
/// ("<bundle>/<Class>/<test>()"), the namespace `xcodebuild -only-testing:`
/// and xcresult both speak.
public struct TestDiscovery: Sendable {

    private let log: Logging?
    private let shell: Run

    public init(log: Logging? = nil) {
        self.log = log
        self.shell = Run()
    }

    /// All tests in the xctestrun's bundles as typed records.
    /// A failure to enumerate fails discovery outright — silently skipping a bundle
    /// would let part of the suite vanish behind exit 0.
    public func tests(
        xctestrun: XCTestRun,
        configuration: String?,
        backend: DiscoveryBackend = .enumeration
    ) async throws -> [ScheduledTest] {
        let descriptors = xctestrun.testBundles(config: configuration)
        let tests: [ScheduledTest]
        switch backend {
        case .enumeration:
            tests = try await enumerationTests(xctestrun: xctestrun, configuration: configuration, descriptors: descriptors)
        case .symbols:
            tests = try await symbolTests(configuration: configuration, descriptors: descriptors)
        }
        // A bundle with ZERO discovered tests fails discovery OUTRIGHT: silently
        // skipping it would let part of the suite vanish behind exit 0. (Remove a
        // genuinely test-less target from the test plan instead.)
        let emptyBundles = descriptors.filter { descriptor in
            !tests.contains { $0.bundleName == descriptor.bundleName }
        }
        guard emptyBundles.isEmpty else {
            throw XCTestRunError(
                "discovery found 0 tests for bundle(s): "
                + emptyBundles.map(\.bundleName).joined(separator: ", ")
                + " (backend: \(backend.rawValue)) — a partial suite must never run silently"
            )
        }
        return tests
    }

    // MARK: - Enumeration backend (xcodebuild -enumerate-tests)

    struct EnumerationDocument: Codable {
        struct Entry: Codable {
            struct Test: Codable { let identifier: String }
            let enabledTests: [Test]
            let disabledTests: [Test]
        }
        let errors: [String]
        let values: [Entry]
    }

    private func enumerationTests(
        xctestrun: XCTestRun,
        configuration: String?,
        descriptors: [TestBundleDescriptor]
    ) async throws -> [ScheduledTest] {
        // One bounded retry: enumeration briefly launches the test runner on the
        // destination, and a busy simulator (e.g. another process enumerating at the
        // same moment) can kill it transiently.
        do {
            return try await enumerationAttempt(xctestrun: xctestrun, configuration: configuration, descriptors: descriptors)
        } catch {
            log?.warning("test enumeration failed, retrying once: \(error)")
            return try await enumerationAttempt(xctestrun: xctestrun, configuration: configuration, descriptors: descriptors)
        }
    }

    private func enumerationAttempt(
        xctestrun: XCTestRun,
        configuration: String?,
        descriptors: [TestBundleDescriptor]
    ) async throws -> [ScheduledTest] {
        let platform = try xctestrun.platform()
        let destination = try await enumerationDestination(for: platform)
        let outputPath = NSTemporaryDirectory() + "sift-enumeration-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        var arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.xctestrunPath,
            "-destination", destination,
            "-enumerate-tests",
            "-test-enumeration-style", "flat",
            "-test-enumeration-format", "json",
            "-test-enumeration-output-path", outputPath,
        ]
        if let configuration {
            arguments += ["-only-test-configuration", configuration]
        }
        log?.message(verboseMsg: "Enumerating tests: xcrun " + arguments.joined(separator: " "))
        let result = try await shell.runUnchecked("/usr/bin/xcrun", arguments)
        guard let data = FileManager.default.contents(atPath: outputPath) else {
            throw XCTestRunError(
                "test enumeration produced no output (xcodebuild status \(result.status)): "
                + String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(2000))
            )
        }
        let document: EnumerationDocument
        do {
            document = try JSONDecoder().decode(EnumerationDocument.self, from: data)
        } catch {
            throw XCTestRunError("cannot parse test enumeration JSON: \(error)")
        }
        // xcodebuild can exit 0 while reporting failures only inside `errors`.
        guard document.errors.isEmpty else {
            throw XCTestRunError(
                "test enumeration failed:\n" + document.errors.map { "  - \($0)" }.joined(separator: "\n")
            )
        }
        return try Self.scheduledTests(
            fromEnumeration: document,
            configuration: configuration,
            descriptors: descriptors,
            log: log
        )
    }

    /// Pure mapping from enumeration JSON to typed tests — shared with unit tests.
    static func scheduledTests(
        fromEnumeration document: EnumerationDocument,
        configuration: String?,
        descriptors: [TestBundleDescriptor],
        log: Logging?
    ) throws -> [ScheduledTest] {
        let byBundle = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.bundleName, $0) })
        var seen = Set<String>()
        var tests: [ScheduledTest] = []
        var disabled = 0
        for entry in document.values {
            disabled += entry.disabledTests.count
            for test in entry.enabledTests {
                let components = test.identifier.components(separatedBy: "/")
                // A method row has >= 2 components: "Bundle/Class/test()", ObjC's
                // paren-less "Bundle/Class/testMethod", or "Bundle/test()" for a
                // suite-less top-level Swift Testing function (TestName.canonical
                // normalizes the parens). A SINGLE-component row is a bundle whose
                // tests xcodebuild could not expand (e.g. its runner crashed) — a
                // FAILED enumeration attempt, never a row to skip: throwing here
                // feeds the bounded retry, then fails the run loudly.
                guard components.count >= 2, let method = components.last else {
                    throw XCTestRunError(
                        "test enumeration returned an unexpanded identifier '\(test.identifier)' — "
                        + "the bundle's tests could not be listed (transient runner crash?)"
                    )
                }
                let bundleName = components[0]
                let classPath = components.dropFirst().dropLast().joined(separator: "/")
                let descriptor = byBundle[bundleName]
                if descriptor == nil {
                    log?.warning("enumerated test '\(test.identifier)' belongs to no known bundle — kept under '\(bundleName)'")
                }
                let scheduled = ScheduledTest(
                    configurationName: configuration,
                    targetKey: descriptor?.targetKey ?? bundleName,
                    productModuleName: descriptor?.productModuleName ?? bundleName,
                    bundleName: bundleName,
                    classPath: classPath,
                    method: TestName.canonical(method)
                )
                if seen.insert(scheduled.id).inserted {
                    tests.append(scheduled)
                }
            }
        }
        if disabled > 0 {
            log?.message(verboseMsg: "Enumeration: \(disabled) test(s) disabled by the test plan — not scheduled")
        }
        return tests
    }

    /// Resolves the `-destination` for enumeration. UI-test bundles refuse
    /// `generic/` destinations ("Tests must be run on a concrete device"), so the
    /// simulator platform picks a concrete local simulator (shutdown is fine).
    func enumerationDestination(for platform: TestPlatform) async throws -> String {
        switch platform {
        case .macOS:
            return "platform=macOS"
        case .simulator:
            let udid = try await localSimulatorUDID()
            return "platform=iOS Simulator,id=\(udid)"
        case .device:
            if let udid = try await localPhysicalDeviceUDID() {
                return "platform=iOS,id=\(udid)"
            }
            throw XCTestRunError(
                "this xctestrun targets physical iOS devices, and no connected device is available "
                + "locally for test enumeration. Connect a device, or use '--discovery symbols' "
                + "(Swift-only symbol scan) for device-platform artifacts."
            )
        }
    }

    private struct SimctlList: Codable {
        struct Device: Codable {
            let udid: String
            let state: String
            let isAvailable: Bool?
        }
        let devices: [String: [Device]]
    }

    private func localSimulatorUDID() async throws -> String {
        let result = try await shell.runChecked("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
        guard let data = result.stdout.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimctlList.self, from: data) else {
            throw XCTestRunError("cannot parse `simctl list devices --json` output")
        }
        let iosRuntimes = list.devices
            .filter { $0.key.contains("SimRuntime.iOS") }
            .sorted { $0.key > $1.key } // newest runtime first
        let available = iosRuntimes.flatMap { $0.value }.filter { $0.isAvailable ?? false }
        if let booted = available.first(where: { $0.state == "Booted" }) {
            return booted.udid
        }
        if let any = available.first {
            return any.udid
        }
        throw XCTestRunError(
            "no available iOS simulator on this machine for test enumeration — "
            + "create one (`xcrun simctl create`) or install an iOS simulator runtime"
        )
    }

    private func localPhysicalDeviceUDID() async throws -> String? {
        guard let result = try? await shell.runChecked("/usr/bin/xcrun", ["xcdevice", "list"]) else { return nil }
        // xcdevice may prefix warnings; locate the JSON array.
        guard let start = result.stdout.firstIndex(of: "["),
              let data = String(result.stdout[start...]).data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let device = entries.first { entry in
            (entry["simulator"] as? Bool) == false
                && ((entry["platform"] as? String)?.contains("iphoneos") ?? false)
                && (entry["available"] as? Bool) == true
        }
        return device?["identifier"] as? String
    }

    // MARK: - Symbols backend (nm + swift-demangle; transitional)

    private func symbolTests(
        configuration: String?,
        descriptors: [TestBundleDescriptor]
    ) async throws -> [ScheduledTest] {
        var tests: [ScheduledTest] = []
        var failures: [String] = []
        for descriptor in descriptors {
            do {
                let identifiers = try await dump(binaryPath: descriptor.executablePath, moduleName: descriptor.bundleName)
                log?.message("\(descriptor.bundleName): \(identifiers.count) tests")
                for identifier in identifiers {
                    let components = identifier.components(separatedBy: "/")
                    guard components.count >= 3, let method = components.last else { continue }
                    tests.append(ScheduledTest(
                        configurationName: configuration,
                        targetKey: descriptor.targetKey,
                        productModuleName: descriptor.productModuleName,
                        bundleName: descriptor.bundleName,
                        classPath: components.dropFirst().dropLast().joined(separator: "/"),
                        method: method
                    ))
                }
            } catch {
                failures.append("\(descriptor.bundleName): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw XCTestRunError(
                "Test discovery failed for \(failures.count) bundle(s):\n" + failures.joined(separator: "\n")
            )
        }
        return tests
    }

    /// Extracts "<name>/Class/testMethod()" identifiers from one binary, where `<name>`
    /// is the caller-provided prefix (the bundle name — the mangled Swift module name
    /// is intentionally not used for the identifier namespace).
    func dump(binaryPath: String, moduleName: String) async throws -> [String] {
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
    /// zero-argument INSTANCE methods prefixed "test". Static/class methods are
    /// rejected — XCTest never runs them, and scheduling one creates a phantom test
    /// that fails the whole run. Internal for unit testing.
    func testIdentifier(fromDemangled line: String, moduleName: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Expected shapes: "Module.Class.testFoo() -> ()", "Module.Class.testFoo()",
        // possibly "@objc Module.Class.testFoo() -> ()".
        guard trimmed.contains("()") else { return nil }
        var signature = trimmed
        if let arrowRange = signature.range(of: " -> ") {
            signature = String(signature[..<arrowRange.lowerBound])
        }
        if signature.hasPrefix("@objc ") {
            signature = String(signature.dropFirst("@objc ".count))
        }
        // "static Module.Class.testFoo()" is not a runnable XCTest.
        guard !signature.hasPrefix("static "), !signature.hasPrefix("class ") else { return nil }
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
