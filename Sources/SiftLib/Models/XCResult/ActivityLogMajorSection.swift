import Foundation

public class ActivityLogMajorSection: ActivityLogSection {
    public let subtitle: String

    enum ActivityLogMajorSectionCodingKeys: String, CodingKey {
        case subtitle
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogMajorSectionCodingKeys.self)
        subtitle = try container.decodeXCResultType(forKey: .subtitle)
        try super.init(from: decoder)
    }
}
