import Foundation

class JUnit {
    var JUnit = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    var testsuites: [String: (tests: Int, failures: Int, time: Double)] = [:]
    var testsuite: [String: (tests: Int, failures: Int, time: Double)] = [:]
    var testcase: [String: (isFailed: Bool, time: Double, message: String)] = [:]
    
    func generate(tests: TestCases) async -> String {
        await tests.cases.values.forEach { test in
            var components = test.name.components(separatedBy: "/")
            let moduleName = components.removeFirst()
            _ = components.removeLast()
            let className = components.joined(separator: "/")
            
            if self.testsuites[moduleName] != nil {
                self.testsuites[moduleName]!.tests += 1
                self.testsuites[moduleName]!.failures += test.state != .pass ? 1 : 0
                self.testsuites[moduleName]!.time += test.duration
            } else {
                self.testsuites[moduleName] = (tests: 1, failures: test.state != .pass ? 1 : 0, time: test.duration)
            }
            
            let moduleClassName = moduleName+"/"+className
            if self.testsuite[moduleClassName] != nil {
                self.testsuite[moduleClassName]!.tests += 1
                self.testsuite[moduleClassName]!.failures += test.state != .pass ? 1 : 0
                self.testsuite[moduleClassName]!.time += test.duration
            } else {
                self.testsuite[moduleClassName] = (tests: 1,
                                                   failures: test.state != .pass ? 1 : 0,
                                                   time: test.duration)

            }
            self.testcase[test.name] = (isFailed: test.state != .pass ? true : false,
                                        time: test.duration,
                                        message: test.message)
        }

        testsuites.forEach { (testsuitesName, value) in
            JUnit += "\t<testsuites name=\"\(testsuitesName)\" " +
                                    "tests=\"\(value.tests)\" " +
                                    "failures=\"\(value.failures)\" " +
                                    "time=\"\(value.time)\">\n"
            testsuite
                .filter { (testsuiteName, _) in testsuiteName.hasPrefix(testsuitesName) }
                .forEach { (testsuiteName, value) in
                    let name = testsuiteName.components(separatedBy: "/").dropFirst().joined(separator: "/")
                    JUnit += "\t\t<testsuite name=\"\(name)\" " +
                                            "tests=\"\(value.tests)\" " +
                                            "failures=\"\(value.failures)\" " +
                                            "time=\"\(value.time)\">\n"
                    
                    testcase
                        .filter { (testcaseName, _) in testcaseName.hasPrefix(testsuiteName) }
                        .forEach { (testcaseName, value) in
                            let test = testcaseName.components(separatedBy: "/").last ?? ""
                            JUnit += "\t\t\t<testcase classname=\"\(name)\" name=\"\(test)\" time=\"\(value.time)\">\n"
                            if value.isFailed {
                                JUnit += "\t\t\t\t<failure message=\"Failed\">\(value.message)</failure>\n"
                            }
                            JUnit += "\t\t\t</testcase>\n"
                    }
                    
                    JUnit += "\t\t</testsuite>\n"
            }
            
            JUnit += "\t</testsuites>\n"
        }
        
        return JUnit
    }
}
