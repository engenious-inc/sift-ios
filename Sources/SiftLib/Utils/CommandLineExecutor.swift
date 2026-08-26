import Foundation

actor OutputCollector {
    private var stdOutData = Data()
    private var stdErrData = Data()

    func appendStdOut(_ data: Data) {
        stdOutData.append(data)
    }

    func appendStdErr(_ data: Data) {
        stdErrData.append(data)
    }

    func getData() -> (stdOut: Data, stdErr: Data) {
        return (stdOutData, stdErrData)
    }
}

enum CommandLineExecutor {
    @discardableResult
    static func launchProcess(command: String, arguments: [String]) async throws -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let runCommand = Process()
        let outputCollector = OutputCollector()

        runCommand.executableURL = URL(fileURLWithPath: command)
        runCommand.currentDirectoryPath = NSTemporaryDirectory()
        runCommand.arguments = arguments
        runCommand.standardError = stderrPipe
        runCommand.standardOutput = stdoutPipe

        // Set up async handlers for output
        stdoutPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            Task {
                await outputCollector.appendStdOut(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            Task {
                await outputCollector.appendStdErr(data)
            }
        }

        runCommand.launch()
        runCommand.waitUntilExit()

        try stdoutPipe.fileHandleForReading.close()
        try stderrPipe.fileHandleForReading.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Get final output
        let (stdOutData, stdErrData) = await outputCollector.getData()
        let stdOutString = String(data: stdOutData, encoding: .utf8)
        let stdErrString = String(data: stdErrData, encoding: .utf8)

        return Result(
            standardOut: stdOutString,
            errorOut: stdErrString,
            terminationStatus: runCommand.terminationStatus
        )
    }
}

extension CommandLineExecutor {
    struct Result {
        var standardOut: String?
        var errorOut: String?
        var terminationStatus: Int32
    }
}
