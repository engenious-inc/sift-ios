import Foundation

/// JUnit XML generator. Produces a single-root, fully escaped document:
/// - one <testsuites> root, one <testsuite> per test class (exact grouping, no prefix matching)
/// - <failure> for failed tests, <skipped/> for skipped, <error> for unexecuted
struct JUnit {

    func generate(tests: TestCasesSnapshot, hostname: String = ProcessInfo.processInfo.hostName, timestamp: Date = Date()) -> String {
        let timestampString = ISO8601DateFormatter().string(from: timestamp)
        struct Suite {
            var tests = 0
            var failures = 0
            var errors = 0
            var skipped = 0
            var time = 0.0
            var cases: [TestCase] = []
        }

        var suites: [String: Suite] = [:]
        for test in tests.cases {
            var components = test.name.components(separatedBy: "/")
            if components.count > 1 { components.removeLast() }
            let suiteName = components.joined(separator: ".")
            var suite = suites[suiteName, default: Suite()]
            suite.tests += 1
            suite.time += test.duration
            switch test.state {
            case .failed: suite.failures += 1
            case .unexecuted: suite.errors += 1
            case .skipped: suite.skipped += 1
            case .pass: break
            }
            suite.cases.append(test)
            suites[suiteName] = suite
        }

        let root = XMLElement(name: "testsuites")
        let totals = (
            tests: tests.count,
            failures: tests.failed.count,
            errors: tests.unexecuted.count,
            skipped: tests.skipped.count,
            time: tests.cases.reduce(0.0) { $0 + $1.duration }
        )
        root.setAttributesWith([
            "name": "Sift",
            "tests": String(totals.tests),
            "failures": String(totals.failures),
            "errors": String(totals.errors),
            "skipped": String(totals.skipped),
            "time": String(format: "%.3f", totals.time),
            "timestamp": timestampString,
        ])

        for suiteName in suites.keys.sorted() {
            guard let suite = suites[suiteName] else { continue }
            let suiteElement = XMLElement(name: "testsuite")
            suiteElement.setAttributesWith([
                "name": suiteName,
                "tests": String(suite.tests),
                "failures": String(suite.failures),
                "errors": String(suite.errors),
                "skipped": String(suite.skipped),
                "time": String(format: "%.3f", suite.time),
                "hostname": hostname,
                "timestamp": timestampString,
            ])
            for test in suite.cases.sorted(by: { $0.name < $1.name }) {
                let caseElement = XMLElement(name: "testcase")
                let testMethod = test.name.components(separatedBy: "/").last ?? test.name
                caseElement.setAttributesWith([
                    "classname": suiteName,
                    "name": testMethod,
                    "time": String(format: "%.3f", test.duration),
                ])
                switch test.state {
                case .failed:
                    let failure = XMLElement(name: "failure", stringValue: xmlSanitized(test.message))
                    failure.setAttributesWith(["message": xmlSanitized(firstLine(of: test.message))])
                    caseElement.addChild(failure)
                case .skipped:
                    let skipped = XMLElement(name: "skipped")
                    if !test.message.isEmpty {
                        skipped.setAttributesWith(["message": xmlSanitized(firstLine(of: test.message))])
                    }
                    caseElement.addChild(skipped)
                case .unexecuted:
                    let error = XMLElement(name: "error", stringValue: xmlSanitized(test.message))
                    error.setAttributesWith(["message": xmlSanitized(firstLine(of: test.message.isEmpty ? "Was not executed" : test.message))])
                    caseElement.addChild(error)
                case .pass:
                    break
                }
                suiteElement.addChild(caseElement)
            }
            root.addChild(suiteElement)
        }

        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlString(options: .nodePrettyPrint) + "\n"
    }

    private func firstLine(of message: String) -> String {
        message.components(separatedBy: .newlines).first ?? message
    }

    /// Removes scalars XML 1.0 forbids (raw control characters from app/test output
    /// would otherwise make the whole document unparsable for CI consumers).
    private func xmlSanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                return true
            default:
                return false
            }
        }))
    }
}
