import Foundation

public class ActionTestPlanRunSummaries: Codable {
    public let summaries: [ActionTestPlanRunSummary]

    enum ActionTestPlanRunSummariesCodingKeys: String, CodingKey {
        case summaries
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestPlanRunSummariesCodingKeys.self)
        summaries = try container.decodeXCResultArray(forKey: .summaries)
    }
}
