import Foundation

public struct OrchestratorTestResults: Codable {
    public var runIndex: Int
    public var testResults: [TestResult]?
}

extension OrchestratorTestResults {
    public struct TestResult: Codable {
        public var testId: Int
        public var result: String
        public var errorMessage: String?
    }
}

