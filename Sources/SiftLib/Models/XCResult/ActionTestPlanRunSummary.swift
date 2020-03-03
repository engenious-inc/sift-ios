import Foundation

public class ActionTestPlanRunSummary: ActionAbstractTestSummary {
    public let testableSummaries: [ActionTestableSummary]

    enum ActionTestPlanRunSummaryCodingKeys: String, CodingKey {
        case testableSummaries
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestPlanRunSummaryCodingKeys.self)
        testableSummaries = try container.decodeXCResultArray(forKey: .testableSummaries)
        try super.init(from: decoder)
    }
}
