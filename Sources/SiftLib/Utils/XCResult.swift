import Foundation

struct XCResult {
    var path: String
    private var tool: XCResultTool
    private var _actionsInvocationRecord: ActionsInvocationRecord?
    private var _actionTestableSummary: [ActionTestableSummary]?
    private var _testsMetadata: [ActionTestMetadata]?
    private var _failedTests: [ActionTestSummary]?
    private var _reran: [String: Int]?
    
    init(path xcresultPath: String, tool: XCResultTool) {
        self.path = xcresultPath
        self.tool = tool
    }
    
    private func data(from string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "Can't convert String to Data", code: 1, userInfo: ["result": string])
        }
        return data
    }
}

extension XCResult {
    mutating func actionsInvocationRecord() throws -> ActionsInvocationRecord {
        if let _actionsInvocationRecord = self._actionsInvocationRecord {
            return _actionsInvocationRecord
        }
        let stringResult = try tool.get(format: .json, id: nil, xcresultPath: path)
        let jsonData = try data(from: stringResult)
        self._actionsInvocationRecord = try JSONDecoder().decode(ActionsInvocationRecord.self, from: jsonData)
        return self._actionsInvocationRecord!
    }
    
    mutating func actionTestableSummary() throws -> [ActionTestableSummary] {
        if let _actionTestableSummary = self._actionTestableSummary {
            return _actionTestableSummary
        }
        self._actionTestableSummary = try self.actionsInvocationRecord().actions
        .compactMap { actionRecord throws -> ActionTestPlanRunSummaries? in
            guard let testRef = actionRecord.actionResult.testsRef else { return nil }
            return try? modelFrom(reference: testRef)
        }.flatMap { actionTestPlanRunSummaries -> [ActionTestPlanRunSummary] in
            actionTestPlanRunSummaries.summaries
        }.flatMap { actionTestPlanRunSummary -> [ActionTestableSummary] in
            actionTestPlanRunSummary.testableSummaries
        }
        return self._actionTestableSummary!
    }
    
    mutating func testsMetadata() throws -> [ActionTestMetadata] {
        if let _testsMetadata = self._testsMetadata {
            return _testsMetadata
        }
        self._testsMetadata = try actionTestableSummary().compactMap { actionTestableSummary -> [ActionTestMetadata]? in
            let testMetadata = actionTestableSummary.getTestsData()?.testMetadata
            testMetadata?.forEach {
                $0.identifier = "\(actionTestableSummary.targetName!)/\($0.identifier!)"
            }
            return testMetadata
        }.flatMap { $0 }
        return self._testsMetadata!
    }
    
    mutating func failedTests() throws -> [ActionTestSummary] {
        if let _failedTests = self._failedTests {
            return _failedTests
        }
        self._failedTests = try self.testsMetadata().compactMap { meta throws -> ActionTestSummary? in
            guard let summaryRef = meta.summaryRef,
                  let testsSummary: ActionTestSummary = try? modelFrom(reference: summaryRef) else {
                return nil
            }
            testsSummary.identifier = meta.identifier
            return testsSummary
        }.filter { actionTestSummary in
            actionTestSummary.testStatus == "Failure"
        }.filter { actionTestSummary in
            try self.testsMetadata().filter {
                $0.identifier == actionTestSummary.identifier && $0.testStatus == "Success"
            }.count == 0
        }.uniqueElements()
        return self._failedTests!
    }
    
    mutating func reran() throws -> [String: Int] {
        if let _reran = self._reran {
            return _reran
        }
        var result = [String: Int]()
        try self.testsMetadata().forEach {
            if let id = $0.identifier {
                result[id, default: -1] += 1
            }
        }
        self._reran = result.filter { $0.value > 0 }
        return self._reran ?? [:]
    }
    
    func modelFrom<T: Codable>(reference: Reference) throws -> T {
        if reference.targetType?.getType() != T.self {
            throw NSError(domain: "Can't extract model from reference id: '\(reference.id)'. " +
                "Type mismatch, expectet type: '\(String(describing:T.self))', " +
                "actual type: '\(String(describing: reference.targetType?.getType()))'", code: 1, userInfo: nil)
        }

        let summaryGetResult = try self.tool.get(format: .json,
                                                 id: reference.id,
                                                 xcresultPath: self.path)
        let referenceData = try data(from: summaryGetResult)
        return try JSONDecoder().decode(T.self, from: referenceData)
    }
}
