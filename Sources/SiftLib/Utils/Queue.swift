import Foundation

class Queue {
    
    enum QueueType {
        case serial
        case concurrent
    }
    
    private let queue: DispatchQueue
    private let name: String
    
    
    init(type: QueueType, name: String, qos: DispatchQoS = .unspecified) {
        self.name = name
        switch type {
        case .serial:
            self.queue = .init(label: name, qos: qos)
        case .concurrent:
            self.queue = .init(label: name, qos: qos, attributes: .concurrent)
        }
    }
    
    func sync<T>(flags: DispatchWorkItemFlags = [], execute: @escaping () throws -> T) rethrows -> T {
        if Thread.current.threadName != name {
            return try self.queue.sync(flags: flags, execute: execute)
        } else {
            return try execute()
        }
    }
    
    func async(flags: DispatchWorkItemFlags = [], qos: DispatchQoS = .default, execute: @escaping () -> Void) {
        if Thread.current.threadName != name {
            self.queue.async(group: nil, qos: qos, flags: flags, execute: execute)
        } else {
            execute()
        }
    }
}
