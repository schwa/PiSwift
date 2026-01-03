import Foundation
import PiSwiftAI

public final class HookRunner: @unchecked Sendable {
    private var hooks: [LoadedHook]
    private let cwd: String
    private let sessionManager: SessionManager
    private let modelRegistry: ModelRegistry
    private var getModel: () -> Model?
    private var hasUI: Bool

    public init(_ hooks: [LoadedHook], _ cwd: String, _ sessionManager: SessionManager, _ modelRegistry: ModelRegistry) {
        self.hooks = hooks
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.getModel = { nil }
        self.hasUI = false
    }

    public func initialize(
        getModel: @escaping () -> Model?,
        hasUI: Bool
    ) {
        self.getModel = getModel
        self.hasUI = hasUI
    }

    public func hasHandlers(_ type: String) -> Bool {
        for hook in hooks {
            if let handlers = hook.handlers[type], !handlers.isEmpty {
                return true
            }
        }
        return false
    }

    public func emit(_ event: HookEvent) async -> Any? {
        let context = HookContext(
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: getModel(),
            hasUI: hasUI
        )
        var lastResult: Any? = nil

        for hook in hooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(event, context) {
                        lastResult = result
                        if let result = result as? SessionBeforeCompactResult, result.cancel {
                            return result
                        }
                        if let result = result as? SessionBeforeTreeResult, result.cancel {
                            return result
                        }
                        if let result = result as? SessionBeforeBranchResult, result.cancel {
                            return result
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        return lastResult
    }
}
