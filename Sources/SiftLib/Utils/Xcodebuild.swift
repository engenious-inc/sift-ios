import Foundation

struct Xcodebuild {
    
    let xcodePath: String
    let shell: ShellExecutor
	let testsExecutionTimeout: Int
	let onlyTestConfiguration: String?
	let skipTestConfiguration: String?
	
    func execute(tests: [String],
                 executorType: TestExecutorType,
                 UDID: String,
                 xctestrunPath: String,
                 derivedDataPath: String,
                 quiet: Bool = true,
                 log: Logging?) async throws -> Int {
        let onlyTestingString = tests.map { "-only-testing:'\($0)'" }.joined(separator: " ")
		let onlyTestConfiguration = onlyTestConfiguration != nil ? "-only-test-configuration '\(onlyTestConfiguration!)' " : ""
		let skipTestConfiguration = skipTestConfiguration != nil ? "-skip-test-configuration '\(skipTestConfiguration!)' " : ""
        let command = "xcodebuild " + (quiet == true ? "-quiet " : "") +
            "-xctestrun '\(xctestrunPath)' " +
            "-destination 'platform=\(executorType.rawValue),id=\(UDID)' " +
            "-derivedDataPath \(derivedDataPath)/\(UDID) " +
            "-test-timeouts-enabled YES " +
			onlyTestConfiguration +
			skipTestConfiguration +
            "\(onlyTestingString) test-without-building"
        log?.message(verboseMsg: "Run command:\n" + command)
        let exitStatusPath = try shell.runInBackground("export DEVELOPER_DIR=\(xcodePath)/Contents/Developer; " + command, temporaryDirectory: derivedDataPath)
        
		let delay = 3
        var result: (status: Int32, output: String) = (1, "")
		for counter in 1...testsExecutionTimeout where result.status != 0 {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            result = try await shell.run("cat \(exitStatusPath)")
			
			guard counter * delay <= testsExecutionTimeout else {
				break
			}
        }
        
        return Int(result.output.replacingOccurrences(of: "\n", with: "")) ?? -1
    }
}
