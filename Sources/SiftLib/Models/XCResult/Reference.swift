import Foundation

public class Reference: Codable {
    public let id: String
    public let targetType: TypeDefinition?

    enum ReferenceCodingKeys: String, CodingKey {
        case id
        case targetType
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ReferenceCodingKeys.self)
        id = try container.decodeXCResultType(forKey: .id)
        targetType = try container.decodeXCResultObjectIfPresent(forKey: .targetType)
    }
}
