import Foundation

public class ActionSDKRecord: Codable {
    public let name: String
    public let identifier: String
    public let operatingSystemVersion: String
    public let isInternal: Bool

    enum ActionSDKRecordCodingKeys: String, CodingKey {
        case name
        case identifier
        case operatingSystemVersion
        case isInternal
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionSDKRecordCodingKeys.self)
        name = try container.decodeXCResultType(forKey: .name)
        identifier = try container.decodeXCResultType(forKey: .identifier)
        operatingSystemVersion = try container.decodeXCResultType(forKey: .operatingSystemVersion)
        isInternal = try container.decodeXCResultTypeIfPresent(forKey: .isInternal) ?? false
    }
}
