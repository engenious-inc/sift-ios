import Foundation

public class ActivityLogTargetBuildSection: ActivityLogMajorSection {
    public let productType: String?

    enum ActivityLogTargetBuildSectionCodingKeys: String, CodingKey {
        case productType
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogTargetBuildSectionCodingKeys.self)
        productType = try container.decodeXCResultTypeIfPresent(forKey: .productType)
        try super.init(from: decoder)
    }
}
