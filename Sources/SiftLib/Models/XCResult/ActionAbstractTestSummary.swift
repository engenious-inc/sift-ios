import Foundation

public class ActionAbstractTestSummary: Codable {
    public let name: String?

    enum ActionAbstractTestSummaryCodingKeys: String, CodingKey {
        case name
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionAbstractTestSummaryCodingKeys.self)
        name = try container.decodeXCResultTypeIfPresent(forKey: .name)
    }
}
