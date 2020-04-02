import Foundation

public protocol Runner {
    var name: String { get }
    var finished: Bool { get }
    var delegate: RunnerDelegate! { get }
    func start()
}
