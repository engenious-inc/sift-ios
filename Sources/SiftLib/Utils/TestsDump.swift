import Foundation

struct TestsDump: Dump {
    
    private let shell: ShellExecutor
    
    init(shell: ShellExecutor = Run()) {
        self.shell = shell
    }
    
    func dump(path: String, moduleName: String) async throws -> [String] {
        let result = try await self.shell.run(Scripts.dumpTests(path: path))
        
        guard result.status == 0 else {
            throw NSError(domain: result.output, code: Int(result.status), userInfo: nil)
        }
        guard result.output.count > 0 else {
            return []
        }
        
        let tests = result.output.replacingOccurrences(of: ".", with: "/")
        return tests.dropLast().components(separatedBy: "\n").map {
            var tmp = $0.components(separatedBy: "/")
            tmp[0] = moduleName
            return tmp.joined(separator: "/")
        }
    }
}
