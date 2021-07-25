import Foundation

enum CommandLineExecutor {
    
	@discardableResult
	static func launchProcess(command: String, arguments: [String], timeout: Double = 60.0) throws -> Result {
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let runCommand = Process()
		
		runCommand.launchPath = command
		runCommand.currentDirectoryPath = NSTemporaryDirectory()
		runCommand.arguments = arguments
		runCommand.standardError = stderrPipe
		runCommand.standardOutput = stdoutPipe
		
		var processTimedOut = false
		DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: {
			if runCommand.isRunning {
				processTimedOut = true
				runCommand.terminate()
			}
		})
		
		do {
            try runCommand.run()
			runCommand.waitUntilExit()
		} catch {
			// handle errors
			throw NSError(domain: "Error starting process for \(command): \(error.localizedDescription)", code: 1, userInfo: nil)
		}
        
        let stdOutString = stdoutPipe.fileHandleForReading.readDataToEndOfFile().string(encoding: .utf8)
        let stdErrString = stderrPipe.fileHandleForReading.readDataToEndOfFile().string(encoding: .utf8)
        
		if processTimedOut {
            throw NSError(domain: "Command terminated due to timeout: \(runCommand.launchPath ?? command)", code: 1, userInfo: nil)
		}
		
		return Result(standardOut: stdOutString, errorOut: stdErrString, terminationStatus: runCommand.terminationStatus)
	}
}

extension CommandLineExecutor {
    
    struct Result {
        var standardOut: String?
        var errorOut: String?
        var terminationStatus: Int32
    }
}
