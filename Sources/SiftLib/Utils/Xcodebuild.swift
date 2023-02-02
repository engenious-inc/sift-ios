import Foundation

struct Xcodebuild {
    
    let xcodePath: String
    let shell: ShellExecutor
    
    func execute(tests: [String],
                 executorType: TestExecutorType,
                 UDID: String,
                 xctestrunPath: String,
                 derivedDataPath: String,
                 quiet: Bool = true,
                 log: Logging?) async throws -> Int {
        let onlyTestingString = tests.map { "-only-testing:'\($0)'" }.joined(separator: " ")
        let command = "xcodebuild " + (quiet == true ? "-quiet " : "") +
            "-xctestrun '\(xctestrunPath)' " +
            "-destination 'platform=\(executorType.rawValue),id=\(UDID)' " +
            "-derivedDataPath \(derivedDataPath)/\(UDID) " +
            "-test-timeouts-enabled YES " +
            "\(onlyTestingString) test-without-building"
        log?.message(verboseMsg: "Run command:\n" + command)
        let exitStatusPath = try shell.runInBackground("export DEVELOPER_DIR=\(xcodePath)/Contents/Developer; " + command, temporaryDirectory: derivedDataPath)
        
        var result: (status: Int32, output: String) = (1, "")
        while result.status != 0 {
            try await Task.sleep(nanoseconds: UInt64(3) * 1_000_000_000)
            result = try shell.run("cat \(exitStatusPath)")
        }
        
        return Int(result.output.replacingOccurrences(of: "\n", with: "")) ?? -1
    }
}
