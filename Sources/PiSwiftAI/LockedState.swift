import Synchronization

public final class LockedState<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: sending Value) {
        mutex = Mutex(value)
    }

    @discardableResult
    public func withLock<T>(_ body: (inout sending Value) throws -> sending T) rethrows -> sending T {
        try mutex.withLock(body)
    }
}
