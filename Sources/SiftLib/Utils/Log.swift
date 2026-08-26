import Foundation

import Rainbow


public protocol Logging: Sendable {
	var quiet: Bool { get set}
	var verbose: Bool {get set }
	
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
        if !quiet {
            let before = before ?? ""
            print("\n" + before + " ⚠️  " + prefix + " " + msg.yellow.bold + "\n")
        }
    }

    func error(before: String? = nil, _ msg: String) {
        let before = before ?? ""
        print("\n" + before + " ⛔️ " + prefix + " " + msg.red.bold + "\n")
    }

    func message(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " • " + prefix + " " + msg)
        }
    }
    
    func message(before: String? = nil, verboseMsg: String) {
        if verbose && !quiet && !verboseMsg.isEmpty {
            print((before ?? "\t") + " > " + prefix + " " + verboseMsg.lightBlack.italic)
        }
    }

    func success(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " ✅ " + prefix + " " + msg.green.bold + "\n")
        }
    }
    
    func skipped(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " ⤵️ " + prefix + " " + msg.green.bold + "\n")
        }
    }

    func failed(before: String? = nil, _ msg: String) {
        if !quiet {
            print((before ?? "") + " ❌ " + prefix + " " + msg.red.bold + "\n")
        }
    }
}

public struct Log: Logging {
	public var quiet: Bool = false
	public var verbose: Bool = false
    public var prefix: String
    public init(prefix: String = "") {
        self.prefix = prefix
    }
}
