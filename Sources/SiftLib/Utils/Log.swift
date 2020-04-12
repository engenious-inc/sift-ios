import Foundation

import Rainbow

public var quiet = false
public var verbose = false

public enum Log {
    public static func warning(before: String? = nil, _ msg: String) {
        if !quiet {
            let before = before ?? ""
            print("\n" + before + " ⚠️  " + msg.yellow.bold + "\n")
        }
    }

    public static func error(before: String? = nil, _ msg: String) {
        if !quiet {
            let before = before ?? ""
            print("\n" + before + " ⛔️ " + msg.red.bold + "\n")
        }
    }

    public static func message(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " • " + msg)
        }
    }
    
    public static func message(before: String? = nil, verboseMsg: String) {
        if verbose && !quiet && !verboseMsg.isEmpty {
            print((before ?? "\t") + " > " + verboseMsg.lightBlack.italic)
        }
    }

    public static func success(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " ✅ " + msg.green.bold + "\n")
        }
    }

    public static func failed(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " ❌ " + msg.red.bold + "\n")
        }
    }
}
