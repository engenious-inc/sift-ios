import Foundation

extension Thread {
    var threadName: String {
        let name = __dispatch_queue_get_label(nil)
        return String(cString: name, encoding: .utf8) ?? Thread.current.description
    }
}
