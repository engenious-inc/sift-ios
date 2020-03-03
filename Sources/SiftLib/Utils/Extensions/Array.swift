import Foundation

extension Array where Element: Hashable {
    public func uniqueElements() -> [Element] {
        return Array(Set(self))
    }
}
