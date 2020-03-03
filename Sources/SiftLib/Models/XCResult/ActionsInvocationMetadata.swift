import Foundation

public class ActionsInvocationMetadata: Codable {
    public let creatingWorkspaceFilePath: String
    public let uniqueIdentifier: String
    public let schemeIdentifier: EntityIdentifier?

    enum ActionsInvocationMetadataCodingKeys: String, CodingKey {
        case creatingWorkspaceFilePath
        case uniqueIdentifier
        case schemeIdentifier
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionsInvocationMetadataCodingKeys.self)
        creatingWorkspaceFilePath = try container.decodeXCResultType(forKey: .creatingWorkspaceFilePath)
        uniqueIdentifier = try container.decodeXCResultType(forKey: .uniqueIdentifier)
        schemeIdentifier = try container.decodeXCResultObjectIfPresent(forKey: .schemeIdentifier)
    }
}
