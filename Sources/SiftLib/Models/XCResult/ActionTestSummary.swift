import Foundation

public enum TestStatus: String {
    case Success
    case Failure
}

public class ActionTestSummary: ActionTestSummaryIdentifiableObject, Hashable {
    public static func == (lhs: ActionTestSummary, rhs: ActionTestSummary) -> Bool {
        lhs.identifier == rhs.identifier && lhs.testStatus == rhs.testStatus
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
        hasher.combine(testStatus)
    }
    
    public let testStatus: String
    public let duration: Double
    public let performanceMetrics: [ActionTestPerformanceMetricSummary]
    public let failureSummaries: [ActionTestFailureSummary]
    public let activitySummaries: [ActionTestActivitySummary]

    enum ActionTestSummaryCodingKeys: String, CodingKey {
        case testStatus
        case duration
        case performanceMetrics
        case failureSummaries
        case activitySummaries
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestSummaryCodingKeys.self)
        duration = try container.decodeXCResultType(forKey: .duration)
        testStatus = try container.decodeXCResultType(forKey: .testStatus)
        performanceMetrics = try container.decodeXCResultArray(forKey: .performanceMetrics)
        failureSummaries = try container.decodeXCResultArray(forKey: .failureSummaries)
        activitySummaries = try container.decodeXCResultArray(forKey: .activitySummaries)
        try super.init(from: decoder)
    }

    public func allChildActivitySummaries() -> [ActionTestActivitySummary] {
        var activitySummaries = self.activitySummaries
        var summariesToCheck = activitySummaries
        repeat {
            summariesToCheck = summariesToCheck.flatMap { $0.subactivities }

            // Add the subactivities we found
            activitySummaries.append(contentsOf: summariesToCheck)
        } while summariesToCheck.count > 0

        return activitySummaries
    }
}
