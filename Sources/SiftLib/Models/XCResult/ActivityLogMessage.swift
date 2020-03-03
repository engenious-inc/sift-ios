import Foundation

public class ActivityLogMessage: Codable {
    public let type: String
    public let title: String
    public let shortTitle: String?
    public let category: String?
    public let location: DocumentLocation?
    public let annotations: [ActivityLogMessageAnnotation]

    enum ActivityLogMessageCodingKeys: String, CodingKey {
        case type
        case title
        case shortTitle
        case category
        case location
        case annotations
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogMessageCodingKeys.self)
        type = try container.decodeXCResultType(forKey: .type)
        title = try container.decodeXCResultType(forKey: .title)
        shortTitle = try container.decodeXCResultTypeIfPresent(forKey: .shortTitle)
        category = try container.decodeXCResultTypeIfPresent(forKey: .category)
        location = try container.decodeXCResultObjectIfPresent(forKey: .location)
        annotations = try container.decodeXCResultArray(forKey: .annotations)
    }
}
