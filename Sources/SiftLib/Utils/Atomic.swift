//
//  Atomic.swift
//  SiftLib
//
//  Created by AP on 11/3/20.
//

import Foundation

@propertyWrapper
public struct Atomic<Value> {
    private let queue: DispatchQueue
    private var value: Value
    
    public init(wrappedValue: Value, queue: DispatchQueue) {
        self.value = wrappedValue
        self.queue = queue
    }
    
    public var wrappedValue: Value {
        get {
            return queue.sync(flags: .barrier) { value }
        }
        set {
            queue.sync(flags: .barrier) { value = newValue }
        }
    }
}
