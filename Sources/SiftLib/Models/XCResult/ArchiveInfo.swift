import Foundation

public class ArchiveInfo: Codable {
    public let path: String?

    enum ArchiveInfoCodingKeys: String, CodingKey {
        case path
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ArchiveInfoCodingKeys.self)
        path = try container.decodeXCResultTypeIfPresent(forKey: .path)
    }
}
