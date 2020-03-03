import Foundation

public class ActionTestFailureSummary: Codable {
    public let message: String?
    public let fileName: String
    public let lineNumber: Int
    public let isPerformanceFailure: Bool

    enum ActionTestFailureSummaryCodingKeys: String, CodingKey {
        case message
        case fileName
        case lineNumber
        case isPerformanceFailure
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestFailureSummaryCodingKeys.self)
        message = try container.decodeXCResultTypeIfPresent(forKey: .message)
        fileName = try container.decodeXCResultType(forKey: .fileName)
        lineNumber = try container.decodeXCResultType(forKey: .lineNumber)
        isPerformanceFailure = try container.decodeXCResultType(forKey: .isPerformanceFailure)
    }
}
