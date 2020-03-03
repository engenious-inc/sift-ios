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
                 timeout: Int) throws -> (status: Int32, output: String) {
        let onlyTestingString = tests.map { "-only-testing:'\($0)'" }.joined(separator: " ")
        let command = "xcodebuild " + (quiet == true ? "-quiet " : "") +
            "-xctestrun '\(xctestrunPath)' " +
            "-destination 'platform=\(executorType.rawValue),id=\(UDID)' " +
            "-derivedDataPath \(derivedDataPath)/\(UDID) " +
            "\(onlyTestingString) test-without-building"
        
        return try shell.run("export DEVELOPER_DIR=\(xcodePath)/Contents/Developer\n" +
        "/usr/local/bin/timeout --preserve-status \(timeout) " + command)
    }
}
