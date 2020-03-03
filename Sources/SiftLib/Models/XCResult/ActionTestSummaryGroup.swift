import Foundation

public class ActionTestSummaryGroup: ActionTestSummaryIdentifiableObject {
    public let duration: Double
    public let subtests: [ActionTestSummaryIdentifiableObject]

    enum ActionTestSummaryGroupCodingKeys: String, CodingKey {
        case duration
        case subtests
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestSummaryGroupCodingKeys.self)
        duration = try container.decodeXCResultType(forKey: .duration)
        subtests = try container.decodeXCResultArray(forKey: .subtests)
        try super.init(from: decoder)
    }
}
