import Foundation

/// Persisted per-test duration statistics, keyed by platform + configuration +
/// canonical identifier, updated only from real verdicts (pass/fail — a chunk that
/// never ran a test teaches nothing). Lives at `outputDirectoryPath/.sift/timings.json`;
/// a corrupt or missing file is an empty store, never an error.
public struct TestTimings: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var meanSeconds: Double
        public var samples: Int
    }

    public var version: Int = 1
    public var entries: [String: Entry] = [:]

    private static let sampleCap = 20

    public init() {}

    static func key(platform: TestPlatform, unit: TestUnit) -> String {
        "\(platform.rawValue)|\(unit.configuration ?? "-")|\(unit.test)"
    }

    private static func path(outputDirectoryPath: String) -> String {
        "\(outputDirectoryPath)/.sift/timings.json"
    }

    public static func load(outputDirectoryPath: String, log: Logging?) -> TestTimings {
        let path = path(outputDirectoryPath: outputDirectoryPath)
        guard let data = FileManager.default.contents(atPath: path) else { return TestTimings() }
        do {
            return try JSONDecoder().decode(TestTimings.self, from: data)
        } catch {
            log?.warning("timings store at \(path) is unreadable (\(error)) — starting fresh")
            return TestTimings()
        }
    }

    public func estimates(platform: TestPlatform, units: [TestUnit]) -> [TestUnit: Double] {
        var result: [TestUnit: Double] = [:]
        for unit in units {
            if let entry = entries[Self.key(platform: platform, unit: unit)] {
                result[unit] = entry.meanSeconds
            }
        }
        return result
    }

    /// Rolling mean with a sample cap so ancient history cannot dominate.
    public mutating func record(platform: TestPlatform, unit: TestUnit, duration: Double) {
        guard duration > 0 else { return }
        let key = Self.key(platform: platform, unit: unit)
        if var entry = entries[key] {
            let samples = min(entry.samples, Self.sampleCap)
            entry.meanSeconds = (entry.meanSeconds * Double(samples) + duration) / Double(samples + 1)
            entry.samples = samples + 1
            entries[key] = entry
        } else {
            entries[key] = Entry(meanSeconds: duration, samples: 1)
        }
    }

    /// Atomic, owner-only save. Failures are logged, never fatal — timings are an
    /// optimization, not run state.
    public func save(outputDirectoryPath: String, log: Logging?) {
        let path = Self.path(outputDirectoryPath: outputDirectoryPath)
        do {
            try FileManager.default.createDirectory(atPath: "\(outputDirectoryPath)/.sift",
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            let temporary = path + ".tmp-\(UUID().uuidString)"
            guard FileManager.default.createFile(atPath: temporary, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                log?.warning("cannot write timings store at \(temporary)")
                return
            }
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
        } catch {
            log?.warning("cannot save timings store: \(error)")
        }
    }
}
