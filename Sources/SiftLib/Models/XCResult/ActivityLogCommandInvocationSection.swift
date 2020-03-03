import Foundation

public class ActivityLogCommandInvocationSection: ActivityLogSection {
    public let commandDetails: String
    public let emittedOutput: String
    public let exitCode: Int?

    enum ActivityLogCommandInvocationSectionCodingKeys: String, CodingKey {
        case commandDetails
        case emittedOutput
        case exitCode
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogCommandInvocationSectionCodingKeys.self)
        commandDetails = try container.decodeXCResultType(forKey: .commandDetails)
        emittedOutput = try container.decodeXCResultType(forKey: .emittedOutput)
        exitCode = try container.decodeXCResultTypeIfPresent(forKey: .exitCode)
        try super.init(from: decoder)
    }
}
