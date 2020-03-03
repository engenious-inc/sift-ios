import Foundation

public class ActionTestableSummary: ActionAbstractTestSummary {
    public let projectRelativePath: String?
    public let targetName: String?
    public let testKind: String?
    public let tests: [ActionTestSummaryIdentifiableObject]
    public let diagnosticsDirectoryName: String?
    public let failureSummaries: [ActionTestFailureSummary]
    public let testLanguage: String?
    public let testRegion: String?

    enum ActionTestableSummaryCodingKeys: String, CodingKey {
        case projectRelativePath
        case targetName
        case testKind
        case tests
        case diagnosticsDirectoryName
        case failureSummaries
        case testLanguage
        case testRegion
    }

     required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionTestableSummaryCodingKeys.self)
        projectRelativePath = try container.decodeXCResultTypeIfPresent(forKey: .projectRelativePath)
        targetName = try container.decodeXCResultTypeIfPresent(forKey: .targetName)
        testKind = try container.decodeXCResultTypeIfPresent(forKey: .testKind)
        tests = try container.decodeXCResultArray(forKey: .tests)
        diagnosticsDirectoryName = try container.decodeXCResultTypeIfPresent(forKey: .diagnosticsDirectoryName)
        failureSummaries = try container.decodeXCResultArray(forKey: .failureSummaries)
        testLanguage = try container.decodeXCResultTypeIfPresent(forKey: .testLanguage)
        testRegion = try container.decodeXCResultTypeIfPresent(forKey: .testRegion)
        try super.init(from: decoder)
    }
    
    public func getTestsData() -> (testSummaries: [ActionTestSummary], testMetadata: [ActionTestMetadata])? {
        var tests: [ActionTestSummaryIdentifiableObject] = self.tests
        var testSummaries: [ActionTestSummary] = []
        var testMetadata: [ActionTestMetadata] = []

        repeat {
            let summaryGroups = tests.compactMap { (identifiableObj) -> ActionTestSummaryGroup? in
                if let testSummaryGroup = identifiableObj as? ActionTestSummaryGroup {
                    return testSummaryGroup
                } else {
                    return nil
                }
            }

            let summaries = tests.compactMap { (identifiableObj) -> ActionTestSummary? in
                if let testSummary = identifiableObj as? ActionTestSummary {
                    return testSummary
                } else {
                    return nil
                }
            }
            testSummaries.append(contentsOf: summaries)

            let metadata = tests.compactMap { (identifiableObj) -> ActionTestMetadata? in
                if let metadata = identifiableObj as? ActionTestMetadata {
                    return metadata
                } else {
                    return nil
                }
            }
            testMetadata.append(contentsOf: metadata)
            tests = summaryGroups.flatMap { $0.subtests }
        } while tests.count > 0
        
        return (testSummaries, testMetadata)
    }
}
