import Foundation

enum CommandLineExecutor {
    
	@discardableResult
	static func launchProcess(command: String, arguments: [String], timeout: Double = 120.0) throws -> Result {
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let runCommand = Process()
        
        var stdOutData = Data()
        var stdErrData = Data()
		
		runCommand.executableURL = URL(fileURLWithPath: command)
		runCommand.currentDirectoryPath = NSTemporaryDirectory()
		runCommand.arguments = arguments
		runCommand.standardError = stderrPipe
		runCommand.standardOutput = stdoutPipe
        
        let outputQueue = DispatchQueue(label: "bash-output-queue")
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { (handler) in
            let data = handler.availableData
            outputQueue.async {
                stdOutData.append(data)
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { (handler) in
            let data = handler.availableData
            outputQueue.async {
                stdErrData.append(data)
            }
        }
		
		var processTimedOut = false
		DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: {
			if runCommand.isRunning {
				processTimedOut = true
				runCommand.terminate()
			}
		})
		
        runCommand.launch()
        runCommand.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        
		if processTimedOut {
            throw NSError(domain: "Command terminated due to timeout: \(runCommand.launchPath ?? command)\(arguments.joined(separator: ""))", code: 1, userInfo: nil)
		}
		
        return outputQueue.sync {
            let stdOutString = String(data: stdOutData, encoding: .utf8)
            let stdErrString = String(data: stdErrData, encoding: .utf8)
            return Result(standardOut: stdOutString, errorOut: stdErrString, terminationStatus: runCommand.terminationStatus)
        }
	}
}

extension CommandLineExecutor {
    
    struct Result {
        var standardOut: String?
        var errorOut: String?
        var terminationStatus: Int32
    }
}
