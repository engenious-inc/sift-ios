import Foundation

class XCResultType: Codable {
    let name: String
    
    private enum CodingKeys: String, CodingKey {
        case name = "_name"
    }
}

class XCResultArrayValue<T: Codable>: Codable {
    let values: [T]
    
    private enum CodingKeys: String, CodingKey {
        case values = "_values"
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode(family: XCResultTypeFamily.self, forKey: .values)
    }
}

class XCResultValueType: Codable {
    let type: XCResultType
    let value: String
    
    private enum CodingKeys : String, CodingKey {
        case type = "_type"
        case value = "_value"
    }
    
    func getValue() -> Any? {
        if self.type.name == "Bool" {
            return Bool(self.value)
        } else if self.type.name == "Date" {
            if #available(OSX 10.14, *) {
                let df = ISO8601DateFormatter()
                df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return df.date(from: self.value)
            } else {
                return self.value
            }
        } else if self.type.name == "Double" {
            return Double(self.value)
        } else if self.type.name == "Int" {
            return Int(self.value)
        } else {
            return self.value
        }
    }
}

class XCResultObject: Codable {
    let type: XCResultObjectType
    
    private enum CodingKeys : String, CodingKey {
        case type = "_type"
    }
}

class XCResultObjectType: Codable {
    let name: String
    let supertype: XCResultObjectType?
    
    private enum CodingKeys : String, CodingKey {
        case name = "_name"
        case supertype = "_supertype"
    }
    
    func getType() -> Decodable.Type {
        if let type = XCResultTypeFamily(rawValue: self.name) {
            return type.getType()
        } else if let parentType = supertype {
            return parentType.getType()
        } else {
            return XCResultObjectType.self
        }
    }
}

protocol ClassFamily: Decodable {
    static var overlook: Overlook { get }
    func getType() -> Decodable.Type
}

enum Overlook: String, CodingKey {
    case type = "_type"
}

enum XCResultTypeFamily: String, ClassFamily, Sendable {
    case ActionAbstractTestSummary
    case ActionDeviceRecord
    case ActionPlatformRecord
    case ActionRecord
    case ActionResult
    case ActionRunDestinationRecord
    case ActionSDKRecord
    case ActionTestActivitySummary
    case ActionTestAttachment
    case ActionTestFailureSummary
    case ActionTestMetadata
    case ActionTestPerformanceMetricSummary
    case ActionTestPlanRunSummaries
    case ActionTestPlanRunSummary
    case ActionTestSummary
    case ActionTestSummaryGroup
    case ActionTestSummaryIdentifiableObject
    case ActionTestableSummary
    case ActionsInvocationMetadata
    case ActionsInvocationRecord
    case ActivityLogAnalyzerControlFlowStep
    case ActivityLogAnalyzerControlFlowStepEdge
    case ActivityLogAnalyzerEventStep
    case ActivityLogAnalyzerResultMessage
    case ActivityLogAnalyzerStep
    case ActivityLogAnalyzerWarningMessage
    case ActivityLogCommandInvocationSection
    case ActivityLogMajorSection
    case ActivityLogMessage
    case ActivityLogMessageAnnotation
    case ActivityLogSection
    case ActivityLogTargetBuildSection
    case ActivityLogUnitTestSection
    case ArchiveInfo
    case Array
    case Bool
    case CodeCoverageInfo
    case Date
    case DocumentLocation
    case Double
    case EntityIdentifier
    case Int
    case IssueSummary
    case ObjectID
    case Reference
    case ResultIssueSummaries
    case ResultMetrics
    case SortedKeyValueArray
    case SortedKeyValueArrayPair
    case String
    case TestFailureIssueSummary
    case TypeDefinition
    
    static let overlook: Overlook = .type
    
    func getType() -> Decodable.Type {
        switch self {
        case .ActionAbstractTestSummary:
            return SiftLib.ActionAbstractTestSummary.self
        case .ActionDeviceRecord:
            return SiftLib.ActionDeviceRecord.self
        case .ActionPlatformRecord:
            return SiftLib.ActionPlatformRecord.self
        case .ActionRecord:
            return SiftLib.ActionRecord.self
        case .ActionResult:
            return SiftLib.ActionResult.self
        case .ActionRunDestinationRecord:
            return SiftLib.ActionRunDestinationRecord.self
        case .ActionSDKRecord:
            return SiftLib.ActionSDKRecord.self
        case .ActionTestActivitySummary:
            return SiftLib.ActionTestActivitySummary.self
        case .ActionTestAttachment:
            return SiftLib.ActionTestAttachment.self
        case .ActionTestFailureSummary:
            return SiftLib.ActionTestActivitySummary.self
        case .ActionTestMetadata:
            return SiftLib.ActionTestMetadata.self
        case .ActionTestPerformanceMetricSummary:
            return SiftLib.ActionTestPerformanceMetricSummary.self
        case .ActionTestPlanRunSummaries:
            return SiftLib.ActionTestPlanRunSummaries.self
        case .ActionTestPlanRunSummary:
            return SiftLib.ActionTestPlanRunSummary.self
        case .ActionTestSummary:
            return SiftLib.ActionTestSummary.self
        case .ActionTestSummaryGroup:
            return SiftLib.ActionTestSummaryGroup.self
        case .ActionTestSummaryIdentifiableObject:
            return SiftLib.ActionTestSummaryIdentifiableObject.self
        case .ActionTestableSummary:
            return SiftLib.ActionTestableSummary.self
        case .ActionsInvocationMetadata:
            return SiftLib.ActionsInvocationMetadata.self
        case .ActionsInvocationRecord:
            return SiftLib.ActionsInvocationRecord.self
        case .ActivityLogAnalyzerControlFlowStep:
            return SiftLib.ActivityLogAnalyzerControlFlowStep.self
        case .ActivityLogAnalyzerControlFlowStepEdge:
            return SiftLib.ActivityLogAnalyzerControlFlowStepEdge.self
        case .ActivityLogAnalyzerEventStep:
            return SiftLib.ActivityLogAnalyzerEventStep.self
        case .ActivityLogAnalyzerResultMessage:
            return SiftLib.ActivityLogAnalyzerResultMessage.self
        case .ActivityLogAnalyzerStep:
            return SiftLib.ActivityLogAnalyzerStep.self
        case .ActivityLogAnalyzerWarningMessage:
            return SiftLib.ActivityLogAnalyzerWarningMessage.self
        case .ActivityLogCommandInvocationSection:
            return SiftLib.ActivityLogCommandInvocationSection.self
        case .ActivityLogMajorSection:
            return SiftLib.ActivityLogMajorSection.self
        case .ActivityLogMessage:
            return SiftLib.ActivityLogMessage.self
        case .ActivityLogMessageAnnotation:
            return SiftLib.ActivityLogMessageAnnotation.self
        case .ActivityLogSection:
            return SiftLib.ActivityLogSection.self
        case .ActivityLogTargetBuildSection:
            return SiftLib.ActivityLogTargetBuildSection.self
        case .ActivityLogUnitTestSection:
            return SiftLib.ActivityLogUnitTestSection.self
        case .ArchiveInfo:
            return SiftLib.ArchiveInfo.self
        case .Array:
            return SiftLib.XCResultArrayValue<XCResultObject>.self
        case .Bool:
            return SiftLib.XCResultValueType.self
        case .CodeCoverageInfo:
            return SiftLib.CodeCoverageInfo.self
        case .Date:
            return SiftLib.XCResultValueType.self
        case .DocumentLocation:
            return SiftLib.DocumentLocation.self
        case .Double:
            return SiftLib.XCResultValueType.self
        case .EntityIdentifier:
            return SiftLib.EntityIdentifier.self
        case .Int:
            return SiftLib.XCResultValueType.self
        case .IssueSummary:
            return SiftLib.IssueSummary.self
        case .ObjectID:
            return SiftLib.ObjectID.self
        case .Reference:
            return SiftLib.Reference.self
        case .ResultIssueSummaries:
            return SiftLib.ResultIssueSummaries.self
        case .ResultMetrics:
            return SiftLib.ResultMetrics.self
        case .SortedKeyValueArray:
            return AnyObject.self as! Decodable.Type
        case .SortedKeyValueArrayPair:
            return AnyObject.self as! Decodable.Type
        case .String:
            return SiftLib.XCResultValueType.self
        case .TestFailureIssueSummary:
            return SiftLib.TestFailureIssueSummary.self
        case .TypeDefinition:
            return SiftLib.TypeDefinition.self
        }
    }
}
