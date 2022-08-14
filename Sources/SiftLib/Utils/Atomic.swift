import Foundation

actor Atomic<T: Sendable> {
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

extension Atomic where T == Array<String> {
   
    func get(element index: Int) -> T.Element {
        _value[0]
    }
    
    func append(value: T.Element) {
        _value.append(value)
    }
}
