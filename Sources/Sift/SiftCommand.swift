@preconcurrency import ArgumentParser
import Foundation
import SiftLib

@main
struct Sift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sift",
        abstract: "A utility for parallel XCTest execution.",
        subcommands: [RunCommand.self, ListCommand.self],
        defaultSubcommand: RunCommand.self
    )
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

        func validate() throws {
            if let timeout, timeout < 1 {
                throw ValidationError("--timeout must be >= 1 second (got \(timeout))")
            }
        }

        func run() async throws {
            setbuf(__stdoutp, nil)
            var log = Log()
            log.verbose = verboseMode

            var tests: [String] = onlyTesting
            if let testsPath {
                tests = try String(contentsOfFile: testsPath, encoding: .utf8)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }

            let config: Config
            do {
                config = try Config(path: path)
            } catch {
                log.error("\(error)")
                throw ExitCode(64) // EX_USAGE: bad configuration
            }

            let runTask = Task {
                var controller = Controller(
                    config: config,
                    tests: tests,
                    allowEmptyTests: allowEmptyTests,
                    log: log
                )
                return try await controller.run()
            }

            // SIGINT/SIGTERM cancel the run instead of killing the process outright,
            // so remote processes are terminated and partial reports still land.
            let sigintSource = Self.installSignalHandler(SIGINT) { runTask.cancel() }
            let sigtermSource = Self.installSignalHandler(SIGTERM) { runTask.cancel() }
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
                    runTask.cancel()
                }
            }

            do {
                let outcome = try await runTask.value
                timeoutTask?.cancel()
                if runTask.isCancelled {
                    throw ExitCode(124) // timed out / interrupted, reports were still written
                }
                throw outcome.succeeded ? ExitCode.success : ExitCode.failure
            } catch let exit as ExitCode {
                throw exit
            } catch {
                timeoutTask?.cancel()
                log.error("\(error)")
                throw ExitCode(runTask.isCancelled ? 124 : 1)
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

        @Option(name: [.customShort("c"), .customLong("config")], help: "Path to the JSON config file.")
        var path: String

        func run() async throws {
            var log = Log()
            log.quiet = true
            do {
                let config = try Config(path: path)
                var controller = Controller(config: config, log: log)
                // Discovery only: no build zipping, no SSH connections.
                let tests = try await controller.discoverTests()
                for test in tests.sorted() {
                    print(test)
                }
            } catch {
                let errorLog = Log()
                errorLog.error("\(error)")
                throw ExitCode.failure
            }
        }
    }
}
