import Foundation

public class ActivityLogUnitTestSection: ActivityLogSection {
    public let testName: String?
    public let suiteName: String?
    public let summary: String?
    public let emittedOutput: String?
    public let performanceTestOutput: String?
    public let testsPassedString: String?
    public let runnablePath: String?
    public let runnableUTI: String?

    enum ActivityLogUnitTestSectionCodingKeys: String, CodingKey {
        case testName
        case suiteName
        case summary
        case emittedOutput
        case performanceTestOutput
        case testsPassedString
        case runnablePath
        case runnableUTI
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActivityLogUnitTestSectionCodingKeys.self)
        testName = try container.decodeXCResultTypeIfPresent(forKey: .testName)
        suiteName = try container.decodeXCResultTypeIfPresent(forKey: .suiteName)
        summary = try container.decodeXCResultTypeIfPresent(forKey: .summary)
        emittedOutput = try container.decodeXCResultTypeIfPresent(forKey: .emittedOutput)
        performanceTestOutput = try container.decodeXCResultTypeIfPresent(forKey: .performanceTestOutput)
        testsPassedString = try container.decodeXCResultTypeIfPresent(forKey: .testsPassedString)
        runnablePath = try container.decodeXCResultTypeIfPresent(forKey: .runnablePath)
        runnableUTI = try container.decodeXCResultTypeIfPresent(forKey: .runnableUTI)
        try super.init(from: decoder)
    }
}
