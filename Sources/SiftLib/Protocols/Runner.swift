import Foundation

public protocol Runner: AnyObject {
    var name: String { get }
    var delegate: RunnerDelegate! { get }
    func start() async
}
