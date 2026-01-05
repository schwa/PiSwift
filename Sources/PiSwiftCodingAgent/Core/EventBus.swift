import Foundation

public typealias EventBusHandler = @Sendable (Any?) async throws -> Void

public protocol EventBus: Sendable {
    func emit(_ channel: String, _ data: Any?)
    @discardableResult func on(_ channel: String, _ handler: @escaping EventBusHandler) -> () -> Void
}

public protocol EventBusController: EventBus {
    func clear()
}

public final class EventBusImpl: @unchecked Sendable, EventBusController {
    private let lock = NSLock()
    private var handlers: [String: [(UUID, EventBusHandler)]] = [:]

    public init() {}

    public func emit(_ channel: String, _ data: Any?) {
        let payload = AnySendable(value: data)
        let snapshot: [(UUID, EventBusHandler)]
        lock.lock()
        snapshot = handlers[channel] ?? []
        lock.unlock()

        for (_, handler) in snapshot {
            Task { [payload] in
                do {
                    try await handler(payload.value)
                } catch {
                    logEventBusError(channel, error)
                }
            }
        }
    }

    public func on(_ channel: String, _ handler: @escaping EventBusHandler) -> () -> Void {
        let id = UUID()
        lock.lock()
        handlers[channel, default: []].append((id, handler))
        lock.unlock()
        return { [weak self] in
            self?.removeHandler(channel, id)
        }
    }

    public func clear() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    private func removeHandler(_ channel: String, _ id: UUID) {
        lock.lock()
        if var list = handlers[channel] {
            list.removeAll { $0.0 == id }
            handlers[channel] = list
        }
        lock.unlock()
    }
}

public func createEventBus() -> EventBusController {
    EventBusImpl()
}

private struct AnySendable: @unchecked Sendable {
    let value: Any?
}

private func logEventBusError(_ channel: String, _ error: Error) {
    let message = "Event handler error (\(channel)): \(error)\n"
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
