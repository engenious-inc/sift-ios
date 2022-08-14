import Foundation

func repeatOnFailure<R>(_ block: () throws ->R) rethrows -> R {
    return try block()
}
