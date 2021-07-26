import Foundation

enum CommandLineExecutor {
    
	@discardableResult
	static func launchProcess(command: String, arguments: [String], timeout: Double = 60.0) throws -> Result {
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let runCommand = Process()
        
        let MAX_DATA = 1024 * 1024
        var stdOutData = Data(capacity: MAX_DATA)
        var stdErrData = Data(capacity: MAX_DATA)
		
		runCommand.launchPath = command
		runCommand.currentDirectoryPath = NSTemporaryDirectory()
		runCommand.arguments = arguments
		runCommand.standardError = stderrPipe
		runCommand.standardOutput = stdoutPipe
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { (fileHandle) in
            let availableData = fileHandle.availableData
            if availableData.count > 0 {
                if stdOutData.count + availableData.count > MAX_DATA {
                    Log.error("stdout data exceeds buffer capacity: \(MAX_DATA)")
                } else {
                    stdOutData.append(availableData)
                }
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { (fileHandle) in
            let availableData = fileHandle.availableData
            if availableData.count > 0 {
                if stdErrData.count + availableData.count > MAX_DATA {
                    Log.error("stderror data exceeds buffer capacity: \(MAX_DATA)")
                } else {
                    stdErrData.append(availableData)
                }
            }
        }
		
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
        
        let stdOutString = String(data: stdOutData, encoding: .utf8)
        let stdErrString = String(data: stdErrData, encoding: .utf8)
        
		if processTimedOut {
            throw NSError(domain: "Command terminated due to timeout: \(runCommand.launchPath ?? command)\(arguments.joined(separator: ""))", code: 1, userInfo: nil)
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
