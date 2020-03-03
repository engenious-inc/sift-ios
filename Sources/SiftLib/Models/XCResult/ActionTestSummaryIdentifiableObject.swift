import Foundation

public class ActionTestSummaryIdentifiableObject: ActionAbstractTestSummary {
    public var identifier: String?

    enum ActionTestSummaryIdentifiableObjectCodingKeys: String, CodingKey {
        case identifier
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestSummaryIdentifiableObjectCodingKeys.self)
        identifier = try container.decodeXCResultTypeIfPresent(forKey: .identifier)
        try super.init(from: decoder)
    }
}
