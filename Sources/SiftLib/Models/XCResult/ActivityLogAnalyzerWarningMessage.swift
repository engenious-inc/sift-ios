import Foundation

public class ActivityLogAnalyzerWarningMessage: ActivityLogMessage {

     required public init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}
