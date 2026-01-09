import Foundation
import PiSwiftAI

public typealias EventBusHandler = @Sendable ((any Sendable)?) async throws -> Void

public protocol EventBus: Sendable {
    func emit(_ channel: String, _ data: (any Sendable)?)
    @discardableResult func on(_ channel: String, _ handler: @escaping EventBusHandler) -> () -> Void
}

public protocol EventBusController: EventBus {
    func clear()
}

public final class EventBusImpl: Sendable, EventBusController {
    private let state = LockedState([String: [(UUID, EventBusHandler)]]())

    public init() {}

    public func emit(_ channel: String, _ data: (any Sendable)?) {
        let payload = data
        let snapshot = state.withLock { handlers in
            handlers[channel] ?? []
        }

        for (_, handler) in snapshot {
            Task { [payload] in
                do {
                    try await handler(payload)
                } catch {
                    logEventBusError(channel, error)
                }
            }
        }
    }

    public func on(_ channel: String, _ handler: @escaping EventBusHandler) -> () -> Void {
        let id = UUID()
        state.withLock { handlers in
            handlers[channel, default: []].append((id, handler))
        }
        return { [weak self] in
            self?.removeHandler(channel, id)
        }
    }

    public func clear() {
        state.withLock { handlers in
            handlers.removeAll()
        }
    }

    private func removeHandler(_ channel: String, _ id: UUID) {
        state.withLock { handlers in
            if var list = handlers[channel] {
                list.removeAll { $0.0 == id }
                handlers[channel] = list
            }
        }
    }
}

public func createEventBus() -> EventBusController {
    EventBusImpl()
}

private func logEventBusError(_ channel: String, _ error: Error) {
    let message = "Event handler error (\(channel)): \(error)\n"
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
