import Foundation

public class ActionRecord: Codable {
    public let schemeCommandName: String
    public let schemeTaskName: String
    public let title: String?
    public let startedTime: Date
    public let endedTime: Date
    public let runDestination: ActionRunDestinationRecord
    public let buildResult: ActionResult
    public let actionResult: ActionResult

    enum ActionRecordCodingKeys: String, CodingKey {
        case schemeCommandName
        case schemeTaskName
        case title
        case startedTime
        case endedTime
        case runDestination
        case buildResult
        case actionResult
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionRecordCodingKeys.self)
        schemeCommandName = try container.decodeXCResultType(forKey: .schemeCommandName)
        schemeTaskName = try container.decodeXCResultType(forKey: .schemeTaskName)
        title = try container.decodeXCResultTypeIfPresent(forKey: .title)
        startedTime = try container.decodeXCResultType(forKey: .startedTime)
        endedTime = try container.decodeXCResultType(forKey: .endedTime)
        runDestination = try container.decodeXCResultObject(forKey: .runDestination)
        buildResult = try container.decodeXCResultObject(forKey: .buildResult)
        actionResult = try container.decodeXCResultObject(forKey: .actionResult)
    }
}
