import Foundation

public protocol Runner: class {
    var name: String { get }
    var finished: Bool { get set }
    var delegate: RunnerDelegate! { get }
    func start()
}
