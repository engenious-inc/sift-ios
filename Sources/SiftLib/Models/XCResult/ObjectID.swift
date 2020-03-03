import Foundation

public class ObjectID: Codable {
    public let hash: String

    enum ObjectIDCodingKeys: String, CodingKey {
        case hash
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ObjectIDCodingKeys.self)
        hash = try container.decodeXCResultType(forKey: .hash)
    }
}
