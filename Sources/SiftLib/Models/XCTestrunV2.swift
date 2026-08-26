import Foundation

public struct XCTestRunV2: XCTestRun {
	
	var testConfigurations: [TestConfiguration]
	var testPlan: TestPlan
	var xctestrunMetadata: XctestrunMetadata?
	
	enum CodingKeys: String, CodingKey {
		case testConfigurations = "TestConfigurations"
		case testPlan = "TestPlan"
		case xctestrunMetadata = "__xctestrun_metadata__"
	}
	
	public private(set) var testRootPath = ""
	public private(set) var xctestrunFileName = ""
	
	public func testBundleExecPaths(config: String?) -> [(target: String, path: String)] {
		guard let testConfig = self.testConfigurations.first(where: { config == nil ? true : $0.name == config }) else {
			return []
		}
		
		return testConfig.testTargets.compactMap {
			guard let path = $0.testBundleExecPath?.replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath) else {
				return nil
			}
			return ($0.productModuleName, path)
		}
	}
	
	public func dependentProductPaths(config: String?) -> [String] {
		guard let testConfig = self.testConfigurations.first(where: { config == nil ? true : $0.name == config }) else {
			return []
		}
		
		return testConfig.testTargets
			.flatMap { $0.dependentProductPaths }
			.map { $0.replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath) }
	}
	
	public func onlyTestIdentifiers(config: String?) -> [String: [String]] {
		guard let testConfig = self.testConfigurations.first(where: { config == nil ? true : $0.name == config }) else {
			return [:]
		}
		
		return testConfig.testTargets
			.reduce([String: [String]]()) { (result, target) -> [String: [String]] in
				var result = result
				result[target.productModuleName] = target.onlyTestIdentifiers ?? []
				return result
			}
	}
	
	public func skipTestIdentifiers(config: String?) -> [String: [String]] {
		guard let testConfig = self.testConfigurations.first(where: { config == nil ? true : $0.name == config }) else {
			return [:]
		}
		
		return testConfig.testTargets
			.reduce([String: [String]]()) { (result, target) -> [String: [String]] in
				var result = result
				result[target.productModuleName] = target.skipTestIdentifiers ?? []
				return result
			}
	}
	
    mutating public func addEnvironmentVariables(_ values: [String: String]?) {
		guard let values = values, !values.isEmpty else { return }
		self.testConfigurations
			.compactMap { $0.testTargets }
			.flatMap { $0 }
			.forEach {
				$0.environmentVariables?.merge(values) { (_, new) -> String in new }
			}
	}
    
    mutating public func add(timeout: Int) {
        self.testConfigurations
            .compactMap { $0.testTargets }
            .flatMap { $0 }
            .forEach {
                $0.testTimeoutsEnabled = true
                $0.defaultTestExecutionTimeAllowance = timeout
            }
    }
	
	public func save(path: String) throws {
		try (data() as NSData).write(toFile: path)
	}
	
	public func data() throws -> Data {
		return try PropertyListEncoder().encode(self)
	}
	
	init(path: String) throws {
		let data = try NSData(contentsOfFile: path) as Data
		self = try PropertyListDecoder().decode(XCTestRunV2.self, from: data)
		
		let pathComponents = path.components(separatedBy: "/")
		xctestrunFileName = pathComponents.last!
		testRootPath = pathComponents.dropLast().joined(separator: "/")
	}
}

extension XCTestRunV2 {
	
	// MARK: - TestConfiguration
	class TestConfiguration: Codable, @unchecked Sendable {
		var name: String?
		var testTargets: [TestTarget]

		enum CodingKeys: String, CodingKey {
			case name = "Name"
			case testTargets = "TestTargets"
		}
	}

	// MARK: - TestTarget
	class TestTarget: Codable {
		var isXCTRunnerHostedTestBundle, isUITestBundle, testTimeoutsEnabled: Bool?
		var testHostBundleIdentifier: String?
		var useUITargetAppProvidedByTests: Bool?
		var toolchainsSettingValue, uiTargetAppCommandLineArguments: [String]?
		var testLanguage: String?
		var productModuleName: String
		var defaultTestExecutionTimeAllowance: Int?
		var uiTargetAppEnvironmentVariables: [String: String]?
		var userAttachmentLifetime: String?
		var	testHostPath: String
		var onlyTestIdentifiers: [String]?
		var skipTestIdentifiers: [String]?
		var environmentVariables: [String: String]?
		var commandLineArguments: [String]?
		var systemAttachmentLifetime: String?
		var testingEnvironmentVariables: [String: String]?
		var blueprintName, blueprintProviderName, testRegion: String?
		var bundleIdentifiersForCrashReportEmphasis: [String]?
		var testBundlePath: String
		var dependentProductPaths: [String]
        var UITargetAppMainThreadCheckerEnabled: Bool?
        var UITargetAppPath: String?
		
		private var platform: String? {
			if let DYLD_FALLBACK_LIBRARY_PATH = testingEnvironmentVariables?["DYLD_FALLBACK_LIBRARY_PATH"] {
                if DYLD_FALLBACK_LIBRARY_PATH.contains("MacOSX.platform") {
                    return "MacOSX"
                } else if DYLD_FALLBACK_LIBRARY_PATH.contains("iPhoneSimulator.platform") {
                    return "iPhoneSimulator"
                }
                return nil
			}
			
			if let DYLD_LIBRARY_PATH = testingEnvironmentVariables?["DYLD_LIBRARY_PATH"] {
				if DYLD_LIBRARY_PATH.contains("MacOSX.platform") {
					return "MacOSX"
				} else if DYLD_LIBRARY_PATH.contains("iPhoneSimulator.platform") {
					return "iPhoneSimulator"
				}
				return nil
			}
			
			if let DYLD_INSERT_LIBRARIES = testingEnvironmentVariables?["DYLD_INSERT_LIBRARIES"] {
				return DYLD_INSERT_LIBRARIES.contains("iPhoneOS.platform") ? "iPhoneOS" : nil
			}
			
			return nil
		}
		
		//Path to *.xctest/execution file
		var testBundleExecPath: String? {
			let platform = platform ?? "iPhoneSimulator"
			let bundleName = testBundlePath.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? productModuleName
			let path = platform == "MacOSX" ? "\(testBundlePath)/Contents/MacOS/\(bundleName)" : "\(testBundlePath)/\(bundleName)"
			return path.replacingOccurrences(of: "__TESTHOST__", with: testHostPath)
		}
		
		enum CodingKeys: String, CodingKey {
			case isXCTRunnerHostedTestBundle = "IsXCTRunnerHostedTestBundle"
			case isUITestBundle = "IsUITestBundle"
			case testTimeoutsEnabled = "TestTimeoutsEnabled"
			case testHostBundleIdentifier = "TestHostBundleIdentifier"
			case useUITargetAppProvidedByTests = "UseUITargetAppProvidedByTests"
			case toolchainsSettingValue = "ToolchainsSettingValue"
			case uiTargetAppCommandLineArguments = "UITargetAppCommandLineArguments"
			case testLanguage = "TestLanguage"
			case productModuleName = "ProductModuleName"
			case defaultTestExecutionTimeAllowance = "DefaultTestExecutionTimeAllowance"
			case uiTargetAppEnvironmentVariables = "UITargetAppEnvironmentVariables"
			case userAttachmentLifetime = "UserAttachmentLifetime"
			case testHostPath = "TestHostPath"
			case onlyTestIdentifiers = "OnlyTestIdentifiers"
			case skipTestIdentifiers = "SkipTestIdentifiers"
			case environmentVariables = "EnvironmentVariables"
			case commandLineArguments = "CommandLineArguments"
			case systemAttachmentLifetime = "SystemAttachmentLifetime"
			case testingEnvironmentVariables = "TestingEnvironmentVariables"
			case blueprintName = "BlueprintName"
            case blueprintProviderName = "BlueprintProviderName"
			case testRegion = "TestRegion"
			case bundleIdentifiersForCrashReportEmphasis = "BundleIdentifiersForCrashReportEmphasis"
			case testBundlePath = "TestBundlePath"
			case dependentProductPaths = "DependentProductPaths"
            case UITargetAppMainThreadCheckerEnabled = "UITargetAppMainThreadCheckerEnabled"
            case UITargetAppPath = "UITargetAppPath"
		}
	}

	// MARK: - TestPlan
	struct TestPlan: Codable {
		var isDefault: Bool?
		var name: String?

		enum CodingKeys: String, CodingKey {
			case isDefault = "IsDefault"
			case name = "Name"
		}
	}

	// MARK: - XctestrunMetadata
	struct XctestrunMetadata: Codable {
		var formatVersion: Int?

		enum CodingKeys: String, CodingKey {
			case formatVersion = "FormatVersion"
		}
	}
}
