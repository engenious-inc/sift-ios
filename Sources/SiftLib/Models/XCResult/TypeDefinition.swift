import Foundation

public class TypeDefinition: Codable {
    public let name: String
    public let supertype: TypeDefinition?

    enum TypeDefinitionCodingKeys: String, CodingKey {
        case name
        case supertype
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeDefinitionCodingKeys.self)
        name = try container.decodeXCResultType(forKey: .name)
        supertype = try container.decodeXCResultObjectIfPresent(forKey: .supertype)
    }

    public func getType() -> AnyObject.Type {
        if let type = XCResultTypeFamily(rawValue: self.name) {
            return type.getType()
        } else if let parentType = self.supertype {
            return parentType.getType()
        } else {
            return XCResultObjectType.self
        }
    }
}
