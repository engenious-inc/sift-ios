import Foundation

extension String {
    /// POSIX single-quote encoding: safe to interpolate into a `/bin/sh` command line.
    /// Wraps the value in single quotes and escapes embedded single quotes as '\''.
    public var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Array where Element == String {
    /// Joins arguments into a single shell-safe command string.
    public var shellQuotedJoined: String {
        map(\.shellQuoted).joined(separator: " ")
    }
}
