import Foundation

public enum ActionTestAttachmentLifetime: String {
    case keepAlways
    case deleteOnSuccess
}

public class ActionTestAttachment : Codable {
    public let uniformTypeIdentifier: String
    public let name: String?
    public let timestamp: Date?
    public let lifetime: String
    public let inActivityIdentifier: Int
    public let filename: String?
    public let payloadRef: Reference?
    public let payloadSize: Int

    enum ActionTestAttachmentCodingKeys: String, CodingKey {
        case uniformTypeIdentifier
        case name
        case timestamp
        case lifetime
        case inActivityIdentifier
        case filename
        case payloadRef
        case payloadSize
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestAttachmentCodingKeys.self)
        uniformTypeIdentifier = try container.decodeXCResultType(forKey: .uniformTypeIdentifier)
        name = try container.decodeXCResultTypeIfPresent(forKey: .name)
        timestamp = try container.decodeXCResultTypeIfPresent(forKey: .timestamp)
        lifetime = try container.decodeXCResultType(forKey: .lifetime)
        inActivityIdentifier = try container.decodeXCResultType(forKey: .inActivityIdentifier)
        filename = try container.decodeXCResultTypeIfPresent(forKey: .filename)
        payloadRef = try container.decodeXCResultObjectIfPresent(forKey: .payloadRef)
        payloadSize = try container.decodeXCResultType(forKey: .payloadSize)
    }
}
