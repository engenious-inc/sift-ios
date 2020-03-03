import Foundation

public class ActivityLogAnalyzerEventStep: ActivityLogAnalyzerStep {
    public let title: String
    public let location: DocumentLocation?
    public let description: String
    public let callDepth: Int

    enum ActivityLogAnalyzerEventStepCodingKeys: String, CodingKey {
        case title
        case location
        case description
        case callDepth
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogAnalyzerEventStepCodingKeys.self)
        title = try container.decodeXCResultType(forKey: .title)
        location = try container.decodeXCResultObjectIfPresent(forKey: .location)
        description = try container.decodeXCResultType(forKey: .description)
        callDepth = try container.decodeXCResultType(forKey: .callDepth)
        try super.init(from: decoder)
    }
}
