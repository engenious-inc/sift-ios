import Foundation
@preconcurrency import SwiftyJSON

public struct XCTestRunV1: XCTestRun {
    
    let path: String
    var json: JSON
	public private(set) var testRootPath: String
	public private(set) var xctestrunFileName: String
    
    init(path: String) throws {
        self.path = path
        guard let propertyListData = FileManager.default.contents(atPath: path) else {
            throw NSError(domain: "File not found: \(path)", code: 1, userInfo: nil)
        }
        let propertyList = try PropertyListSerialization.propertyList(from: propertyListData,
                                                                      options: .mutableContainersAndLeaves,
                                                                      format: nil)
        self.json = JSON(propertyList)
        let pathComponents = path.components(separatedBy: "/")
        self.testRootPath = pathComponents.dropLast().joined(separator: "/")
		self.xctestrunFileName = pathComponents.last!
    }
	
	//Paths to *.xctest/execution file
	public func testBundleExecPaths(config: String? = nil) -> [(target: String, path: String)] {
		var results: [(target: String, path: String)] = []
		for name in modules() {
			guard let testBundleExecPath = testBundleExecPath(for: name),
				  let target = self.json[name]["ProductModuleName"].string else {
				continue
			}
			results.append((target: target, path: testBundleExecPath))
		}
		return results
	}
	
	public func dependentProductPaths(config: String? = nil) -> [String] {
		return self.json
			.filter { $0.0 != "__xctestrun_metadata__" }
			.flatMap { $0.1["DependentProductPaths"].arrayValue }
			.map { $0.stringValue.replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath) }
	}
	
	public func onlyTestIdentifiers(config: String? = nil) -> [String: [String]] {
		return [:]
	}
	
	// to do
	public func skipTestIdentifiers(config: String? = nil) -> [String: [String]] {
		return [:]
	}
	
	public mutating func addEnvironmentVariables(_ values: [String: String]?) {
		guard let values = values, !values.isEmpty else { return }
		for (key, _) in self.json {
			if key == "__xctestrun_metadata__" { continue }
			try? self.json[key]["EnvironmentVariables"].merge(with: JSON(values))
		}
	}
    
    public mutating func add(timeout: Int) {
        // to do
    }
	
	public func save(path: String) throws {
		try (data() as NSData).write(toFile: path)
	}
	
	public func data() throws -> Data {
		return try PropertyListSerialization.data(fromPropertyList: self.json.rawValue, format: .xml, options: 0)
	}
    
    func modules() -> [String] {
        return self.json.map { $0.0 }.filter { $0 != "__xctestrun_metadata__" }
    }
    
    func productModuleName(for module: String) -> String? {
        return self.json[module]["ProductModuleName"].string
    }
    
    func isUITestBundle(for module: String) -> Bool {
        return self.json[module]["IsUITestBundle"].bool ?? false
    }
    
    func isXCTRunnerHostedTestBundle(for module: String) -> Bool {
        return self.json[module]["IsXCTRunnerHostedTestBundle"].bool ?? false
    }
    
    func isAppHostedTestBundle(for module: String) -> Bool {
        return self.json[module]["IsAppHostedTestBundle"].bool ?? false
    }
    
    func testExecutionOrdering(for module: String) -> String? {
        return self.json[module]["TestExecutionOrdering"].string
    }
    
    //Path to *.app file
    func testHostPath(for module: String) -> String? {
        return self.json[module]["TestHostPath"].string?.replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath)
    }
    
    //Path to *.xctest file
    func testBundlePath(for module: String) -> String? {
        guard let testHostPath = self.testHostPath(for: module) else {
            return nil
        }
        return self.json[module]["TestBundlePath"].string?
            .replacingOccurrences(of: "__TESTROOT__", with: testRootPath)
            .replacingOccurrences(of: "__TESTHOST__", with: testHostPath)
    }
    
    //Path to *.xctest/execution file
    func testBundleExecPath(for module: String) -> String? {
        guard let testBundlePath = testBundlePath(for: module) else {
            return nil
        }
        guard let fileName = testBundlePath.components(separatedBy: "/")
                             .suffix(1)
                             .last?
                             .components(separatedBy: ".")
                             .prefix(1)
                             .last else {
            return nil
        }
		
		if self.json[module]["TestingEnvironmentVariables"]["DYLD_LIBRARY_PATH"].string?.contains("MacOS") ?? false ||
			self.json[module]["TestingEnvironmentVariables"]["DYLD_FRAMEWORK_PATH"].string?.contains("MacOS") ?? false {
			
			return "\(testBundlePath)/Contents/MacOS/\(fileName)"
		}
        return "\(testBundlePath)/\(fileName)"
    }
    
    //Path to *.xctest.dSYM/execution file
    func testBundleExecDSYMPath(for module: String) -> String? {
        guard let testBundlePath = testBundlePath(for: module) else {
            return nil
        }
        guard let fileName = testBundlePath.components(separatedBy: "/")
                             .suffix(1)
                             .last?
                             .components(separatedBy: ".")
                             .prefix(1)
                             .last else {
            return nil
        }
        return "\(testBundlePath).dSYM/Contents/Resources/DWARF/\(fileName)"
    }
    
    //Path to *.xctest.dSYM/execution file
    func testBundleExecDSYMPaths() -> [String: String] {
        
        var results: [String: String] = [:]
        
        for name in modules() {
            guard let testBundlePath = testBundlePath(for: name) else {
                continue
            }
            guard let fileName = testBundlePath.components(separatedBy: "/")
                                                 .suffix(1)
                                                 .last?
                                                 .components(separatedBy: ".")
                                                 .prefix(1)
                                                 .last else {
                continue
            }
            results[name] = "\(testBundlePath).dSYM/Contents/Resources/DWARF/\(fileName)"
        }
        
        return results
    }
    
    func dependentProductPaths(for module: String) -> [String]? {
        return self.json[module]["DependentProductPaths"].array?.map {
            $0.stringValue.replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath)
        }
    }
    
    func dependentProductPathsCuted(for module: String) -> [String]? {
        return self.json[module]["DependentProductPaths"].array?.map {
            $0.stringValue.components(separatedBy: "/")
                .prefix(3)
                .joined(separator: "/")
                .replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath)
        }
    }
    
    func dependentProductPathsCuted() -> [String] {
        return Array(Set(self.json.filter { $0.0 != "__xctestrun_metadata__" }.flatMap {
            $0.1["DependentProductPaths"].arrayValue.map {
                $0.stringValue.components(separatedBy: "/")
                    .prefix(3)
                    .joined(separator: "/")
                    .replacingOccurrences(of: "__TESTROOT__", with: self.testRootPath)
            }
        }))
    }
}
