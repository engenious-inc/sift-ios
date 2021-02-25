import Foundation

public struct TestRun: Codable {
    public var testPlan: TestPlan?
    public var link: String?
    public var runIndex: Int?
    public var date: String?
    
    public init(data: Data) throws {
        self = try JSONDecoder().decode(TestRun.self, from: data)
    }
}

extension  TestRun {
    public struct TestPlan: Codable {
        public var id: Int?
        public var name: String?
        public var platform: Int?
        public var testPlanDefault: Bool?
        public var tests: [Test]?
    }
}

extension  TestRun {
    public struct Test: Codable {
        public var id: Int?
        public var status: Int?
        public var name: String?
        public var testClass: String?
        public var testPackage: String?
        public var lastUpdate: String?
        public var updatedBy: String?
        public var successCount: Int?
        public var testRailLink: String?
        public var jiraLink: String?
        public var comment: String?
    }
}
