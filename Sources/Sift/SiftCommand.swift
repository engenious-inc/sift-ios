@preconcurrency import ArgumentParser
import Foundation
import SiftLib

extension DiscoveryBackend: ExpressibleByArgument {}

@main
struct Sift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sift",
        abstract: "A utility for parallel XCTest execution.",
        subcommands: [RunCommand.self, ListCommand.self, DoctorCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

extension Sift {
    struct DoctorCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doctor",
            abstract: "Preflight a config: tooling, artifact, output directory, every node and executor."
        )

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        func run() async throws {
            let log = Log()
            let config: Config
            do {
                config = try Config(path: path)
            } catch {
                log.error("\(error)")
                throw ExitCode(64)
            }
            var doctor = Doctor(config: config)
            let healthy = await doctor.run()
            if !healthy {
                throw ExitCode.failure
            }
        }
    }
}

extension Sift {

    struct RunCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Test execution command.")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        @Option(name: [.customShort("p"), .customLong("tests-path")], help: "Path to a text file with list of tests for execution.")
        var testsPath: String?

        @Option(name: [.short, .customLong("only-testing")], help: "Test for execution.")
        var onlyTesting: [String] = []

        @Flag(name: [.short, .customLong("verbose")], help: "Verbose mode.")
        var verboseMode: Bool = false

        @Option(name: [.customShort("t"), .customLong("timeout")], help: "Global timeout in seconds for the whole run.")
        var timeout: Int?

        @Flag(name: [.customLong("allow-empty-tests")], help: "Exit successfully when no tests are discovered instead of failing.")
        var allowEmptyTests: Bool = false

        @Option(name: [.customLong("discovery")], help: "Test discovery backend: 'enumeration' (xcodebuild -enumerate-tests, default) or 'symbols' (legacy Swift-only symbol scan; transitional).")
        var discovery: DiscoveryBackend = .enumeration

        @Flag(name: [.customLong("combine-test-selectors")], help: "Allow --tests-path and --only-testing together (their union runs).")
        var combineTestSelectors: Bool = false

        @Option(name: [.customLong("events-path")], help: "Write a machine-readable NDJSON run-event stream (schema v1) to this file.")
        var eventsPath: String?

        @Flag(name: [.customLong("events-stdout")], help: "Echo the NDJSON run-event stream to stdout (use with --quiet-friendly consumers).")
        var eventsStdout: Bool = false

        @Flag(name: [.customLong("disable-tests-results-processing")], help: .hidden)
        var isTestProcessingDisabled: Bool = false

        func validate() throws {
            if let timeout {
                guard timeout >= 1 else {
                    throw ValidationError("--timeout must be >= 1 second (got \(timeout))")
                }
                // 10 years is beyond any real run; also keeps nanosecond conversion
                // far from UInt64 overflow (which would trap at runtime).
                guard timeout <= 315_360_000 else {
                    throw ValidationError("--timeout must be <= 315360000 seconds (got \(timeout))")
                }
            }
        }

        func run() async throws {
            setbuf(__stdoutp, nil)
            var log = Log()
            log.verbose = verboseMode
            // --events-stdout hands stdout to the NDJSON stream: human log lines
            // would corrupt it, so they are quieted (warnings/errors stay on stderr).
            if eventsStdout {
                log.quiet = true
                log.verbose = false
            }

            if isTestProcessingDisabled {
                // Kept for CLI compatibility. Result processing now uses the modern
                // xcresulttool API and is cheap; exit codes always reflect outcomes.
                log.warning("--disable-tests-results-processing is deprecated and has no effect")
            }

            let config: Config
            do {
                config = try Config(path: path)
                try config.validateRuntimeFiles()
            } catch {
                log.error("\(error)")
                throw ExitCode(64) // EX_USAGE: bad configuration
            }

            // Test-source precedence: --only-testing and --tests-path are mutually
            // exclusive unless --combine-test-selectors unions them; the config's
            // `tests` array is a deprecated fallback only when neither is given.
            var tests: [String] = onlyTesting
            if let testsPath {
                let fileTests: [String]
                do {
                    fileTests = try String(contentsOfFile: testsPath, encoding: .utf8)
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } catch {
                    log.error("cannot read --tests-path \(testsPath): \(error.localizedDescription)")
                    throw ExitCode(64)
                }
                if !onlyTesting.isEmpty && !combineTestSelectors {
                    log.error("--tests-path and --only-testing were both given — pass --combine-test-selectors to run their union")
                    throw ExitCode(64)
                }
                tests = onlyTesting + fileTests
            }
            if tests.isEmpty, let configTests = config.tests, !configTests.isEmpty {
                log.warning("the config 'tests' field is deprecated and will be removed — use --only-testing or --tests-path (using it as a fallback for this run)")
                tests = configTests
            }

            // Live progress on a TTY (suppressed in verbose mode — the line would
            // fight the scrolling log) + optional machine-readable event stream.
            let progress = ProgressReporter(
                enabled: isatty(fileno(stdout)) != 0 && !verboseMode && !eventsStdout
            )
            let events = EventBus(
                ndjsonPath: eventsPath,
                echoToStdout: eventsStdout,
                consumers: [progress.consumer]
            )

            let discoveryBackend = discovery
            let runTask = Task {
                var controller = Controller(
                    config: config,
                    tests: tests,
                    allowEmptyTests: allowEmptyTests,
                    discoveryBackend: discoveryBackend,
                    events: events,
                    log: log
                )
                return try await controller.run()
            }

            // SIGINT/SIGTERM cancel the run instead of killing the process outright,
            // so remote processes are terminated and partial reports still land.
            // 124 = timeout, 130 = SIGINT, 143 = SIGTERM (standard shell semantics).
            let cancellationCode = CancellationCode()
            let sigintSource = Self.installSignalHandler(SIGINT) {
                cancellationCode.set(130)
                runTask.cancel()
            }
            let sigtermSource = Self.installSignalHandler(SIGTERM) {
                cancellationCode.set(143)
                runTask.cancel()
            }
            defer {
                sigintSource.cancel()
                sigtermSource.cancel()
            }

            var timeoutTask: Task<Void, Never>?
            if let timeout {
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    log.error("Global timeout (\(timeout)s) reached — cancelling run")
                    cancellationCode.set(124)
                    runTask.cancel()
                }
            }

            do {
                let outcome = try await runTask.value
                timeoutTask?.cancel()
                if let code = cancellationCode.get() {
                    throw ExitCode(code)
                }
                throw outcome.succeeded ? ExitCode.success : ExitCode.failure
            } catch let exit as ExitCode {
                throw exit
            } catch {
                timeoutTask?.cancel()
                log.error("\(error)")
                throw ExitCode(cancellationCode.get() ?? 1)
            }
        }

        private final class CancellationCode: @unchecked Sendable {
            private let lock = NSLock()
            private var code: Int32?
            func set(_ newCode: Int32) {
                lock.lock(); defer { lock.unlock() }
                if code == nil { code = newCode }
            }
            func get() -> Int32? {
                lock.lock(); defer { lock.unlock() }
                return code
            }
        }

        private static func installSignalHandler(_ signalNumber: Int32, handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }

    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Print all tests in bundles.")

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file (nodes are not required for listing).")
        var path: String?

        @Option(name: [.customLong("xctestrun")], help: "List directly from an .xctestrun file — no config needed.")
        var xctestrunPath: String?

        @Option(name: [.customLong("only-test-configuration")], help: "Configuration(s) to include (repeatable). Default: every enabled configuration.")
        var onlyConfigurations: [String] = []

        @Option(name: [.customLong("skip-test-configuration")], help: "Configuration(s) to exclude (repeatable).")
        var skipConfigurations: [String] = []

        @Option(name: [.customLong("discovery")], help: "Test discovery backend: 'enumeration' (default) or 'symbols'.")
        var discovery: DiscoveryBackend = .enumeration

        func validate() throws {
            guard path != nil || xctestrunPath != nil else {
                throw ValidationError("pass --config or --xctestrun")
            }
        }

        func run() async throws {
            var log = Log()
            log.quiet = true
            let errorLog = Log()
            let config: Config
            do {
                if let xctestrunPath {
                    if path != nil {
                        errorLog.warning("--xctestrun overrides the config's xctestrunPath for listing")
                    }
                    let minimal = """
                    {"xctestrunPath": \(String(data: try JSONEncoder().encode(xctestrunPath), encoding: .utf8)!),
                     "outputDirectoryPath": "/tmp", "rerunFailedTest": 0, "testsBucket": 1, "nodes": []}
                    """
                    config = try Config(data: Data(minimal.utf8), role: .list)
                } else {
                    config = try Config(path: path!, role: .list)
                }
                try config.validateRuntimeFiles(role: .list)
            } catch {
                errorLog.error("\(error)")
                throw ExitCode(64) // same mapping as `run`: bad configuration
            }
            do {
                // CLI selector flags win over the config's singular selectors (a notice
                // is printed when they collide).
                var listSelectors: (only: [String], skip: [String])?
                if !onlyConfigurations.isEmpty || !skipConfigurations.isEmpty {
                    if config.onlyTestConfiguration != nil || config.skipTestConfiguration != nil {
                        errorLog.warning("CLI --only/--skip-test-configuration override the config's selectors for this listing")
                    }
                    listSelectors = (onlyConfigurations, skipConfigurations)
                }
                var controller = Controller(config: config, discoveryBackend: discovery, listSelectors: listSelectors, log: log)
                // Discovery only: no build zipping, no SSH connections.
                let tests = try await controller.discoverTests()
                for test in tests.sorted() {
                    print(test)
                }
            } catch {
                errorLog.error("\(error)")
                throw ExitCode.failure
            }
        }
    }
}
