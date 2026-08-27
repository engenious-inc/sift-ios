import Foundation

@preconcurrency import Rainbow

/// Disable colors when stdout is not a terminal or NO_COLOR is set (CI logs).
/// Global-let initialization runs exactly once, before any logging happens.
private final class RainbowConfigurator: @unchecked Sendable {
    static let shared = RainbowConfigurator()
    private init() {
        if isatty(fileno(stdout)) == 0 || ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
            Rainbow.enabled = false
        }
    }
}

/// Strips ASCII control characters (except newline/tab) so node- or test-provided
/// text can never inject terminal escape sequences into the operator's console.
private func sanitized(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter {
        $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F)
    }))
}

/// Errors and warnings go to STDERR; stdout carries command results and progress —
/// `sift list | …` pipelines never see diagnostics.
private func emit(_ line: String, toStandardError: Bool) {
    if toStandardError {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    } else {
        print(line)
    }
}

public protocol Logging: Sendable {
    var quiet: Bool { get set }
    var verbose: Bool { get set }

    var prefix: String { get set }
    func warning(before: String?, _ msg: String)
    func error(before: String?, _ msg: String)
    func message(before: String?, _ msg: String)
    func message(before: String?, verboseMsg: String)
    func success(before: String?, _ msg: String)
    func failed(before: String?, _ msg: String)
}

public extension Logging {
    func warning(before: String? = nil, _ msg: String) {
        // Warnings are diagnostics: emitted even in quiet mode, on stderr.
        let before = before ?? ""
        emit("\n" + before + " ⚠️  " + prefix + " " + sanitized(msg).yellow.bold + "\n", toStandardError: true)
    }

    func error(before: String? = nil, _ msg: String) {
        let before = before ?? ""
        emit("\n" + before + " ⛔️ " + prefix + " " + sanitized(msg).red.bold + "\n", toStandardError: true)
    }

    func message(before: String? = nil, _ msg: String) {
        if !quiet {
            emit((before ?? "") + " • " + prefix + " " + sanitized(msg), toStandardError: false)
        }
    }

    func message(before: String? = nil, verboseMsg: String) {
        if verbose && !quiet && !verboseMsg.isEmpty {
            emit((before ?? "\t") + " > " + prefix + " " + sanitized(verboseMsg).lightBlack.italic, toStandardError: false)
        }
    }

    func success(before: String? = nil, _ msg: String) {
        if !quiet {
            emit((before ?? "") + " ✅ " + prefix + " " + sanitized(msg).green.bold + "\n", toStandardError: false)
        }
    }

    func skipped(before: String? = nil, _ msg: String) {
        if !quiet {
            emit((before ?? "") + " ⤵️ " + prefix + " " + sanitized(msg).green.bold + "\n", toStandardError: false)
        }
    }

    func failed(before: String? = nil, _ msg: String) {
        if !quiet {
            emit((before ?? "") + " ❌ " + prefix + " " + sanitized(msg).red.bold + "\n", toStandardError: false)
        }
    }
}

public struct Log: Logging {
    public var quiet: Bool = false
    public var verbose: Bool = false
    public var prefix: String
    public init(prefix: String = "") {
        _ = RainbowConfigurator.shared
        self.prefix = prefix
    }
}
