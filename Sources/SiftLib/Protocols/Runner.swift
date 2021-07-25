import Foundation

public protocol Runner: AnyObject {
    var name: String { get }
    var finished: Bool { get set }
    var delegate: RunnerDelegate! { get }
    func start()
}
