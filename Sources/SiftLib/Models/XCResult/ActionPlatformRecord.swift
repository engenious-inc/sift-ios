import Foundation

public class ActionPlatformRecord: Codable {
    public let identifier: String
    public let userDescription: String

    enum ActionPlatformRecordCodingKeys: String, CodingKey {
        case identifier
        case userDescription
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionPlatformRecordCodingKeys.self)
        identifier = try container.decodeXCResultType(forKey: .identifier)
        userDescription = try container.decodeXCResultType(forKey: .userDescription)
    }
}
