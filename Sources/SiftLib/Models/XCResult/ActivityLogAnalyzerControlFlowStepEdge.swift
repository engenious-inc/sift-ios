import Foundation

public class ActivityLogAnalyzerControlFlowStepEdge: Codable {
    public let startLocation: DocumentLocation?
    public let endLocation: DocumentLocation?

    enum ActivityLogAnalyzerControlFlowStepEdgeCodingKeys: String, CodingKey {
        case startLocation
        case endLocation
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogAnalyzerControlFlowStepEdgeCodingKeys.self)
        startLocation = try container.decodeXCResultObjectIfPresent(forKey: .startLocation)
        endLocation = try container.decodeXCResultObjectIfPresent(forKey: .endLocation)
    }
}
