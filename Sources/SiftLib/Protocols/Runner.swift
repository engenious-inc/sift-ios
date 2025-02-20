import Foundation

public protocol Runner: Sendable {
    var name: String { get }
    var delegate: RunnerDelegate { get }
	func start() async
}
