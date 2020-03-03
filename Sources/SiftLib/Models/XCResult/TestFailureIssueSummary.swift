import Foundation

public class TestFailureIssueSummary: IssueSummary {
    public let testCaseName: String

    enum TestFailureIssueSummaryCodingKeys: String, CodingKey {
        case testCaseName
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TestFailureIssueSummaryCodingKeys.self)
        testCaseName = try container.decodeXCResultType(forKey: .testCaseName)
        try super.init(from: decoder)
    }
}
