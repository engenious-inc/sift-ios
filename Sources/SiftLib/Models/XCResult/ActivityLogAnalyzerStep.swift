import Foundation

public class ActivityLogAnalyzerStep: Codable {
    public let parentIndex: Int

    enum ActivityLogAnalyzerStepCodingKeys: String, CodingKey {
        case parentIndex
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogAnalyzerStepCodingKeys.self)
        parentIndex = try container.decodeXCResultType(forKey: .parentIndex)
    }
}
