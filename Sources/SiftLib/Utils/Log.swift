import Foundation

import Rainbow

public var quiet = false

public func warning(before: String? = nil, _ msg: String) {
    if !quiet {
        let before = before ?? ""
        print("\n" + before + " ⚠️  " + msg.yellow.bold + "\n")
    }
}

public func error(before: String? = nil, _ msg: String) {
    if !quiet {
        let before = before ?? ""
        print("\n" + before + " ⛔️ " + msg.red.bold + "\n")
    }
}

public func log(before: String? = nil, _ msg: String) {
    if !quiet {
        print((before ?? "") + " • " + msg)
    }
}

public func success(before: String? = nil, _ msg: String) {
    if !quiet {
        print((before ?? "") + " ✅ " + msg.green.bold + "\n")
    }
}

public func failed(before: String? = nil, _ msg: String) {
    if !quiet {
        print((before ?? "") + " ❌ " + msg.red.bold + "\n")
    }
}
