import Foundation

extension Array where Element: Hashable {
    public func uniqueElements() -> [Element] {
        return Array(Set(self))
    }
    
    public func getSet() -> Set<Element> {
        return Set(self)
    }
}

extension Sequence {
    func asyncFilter(
        _ predicate: (Element) async throws -> Bool
    ) async rethrows -> [Element] {
        var result: [Element] = []
        for element in self {
            if try await predicate(element) {
                result.append(element)
            }
        }
        return result
    }
}
