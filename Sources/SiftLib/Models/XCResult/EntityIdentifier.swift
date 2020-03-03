import Foundation

public class EntityIdentifier: Codable {
    public let entityName: String
    public let containerName: String
    public let entityType: String
    public let sharedState: String

    enum EntityIdentifierCodingKeys: String, CodingKey {
        case entityName
        case containerName
        case entityType
        case sharedState
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EntityIdentifierCodingKeys.self)
        entityName = try container.decodeXCResultType(forKey: .entityName)
        containerName = try container.decodeXCResultType(forKey: .containerName)
        entityType = try container.decodeXCResultType(forKey: .entityType)
        sharedState = try container.decodeXCResultType(forKey: .sharedState)
    }
}
