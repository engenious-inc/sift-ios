import Foundation

public actor Atomic<T: Sendable> {
    private var _value: T
    init(value: T) {
        self._value = value
    }
    
    func getValue() -> T {
        return _value
    }
    
    func set(value: T) {
        _value = value
    }
}

public extension Atomic where T == Array<String> {
   
    func get(element index: Int) -> T.Element {
        _value[0]
    }
    
    func append(value: T.Element) {
        _value.append(value)
    }
}

public extension Atomic where T == Int {
   
    @discardableResult
    func increment() -> Int {
        _value += 1
        return _value
    }
}
