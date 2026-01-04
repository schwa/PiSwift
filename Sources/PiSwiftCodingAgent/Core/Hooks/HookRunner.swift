import Foundation
import PiSwiftAI
import PiSwiftAgent

public final class HookRunner: @unchecked Sendable {
    private var hooks: [LoadedHook]
    private let cwd: String
    private let sessionManager: SessionManager
    private let modelRegistry: ModelRegistry
    private var getModel: () -> Model?
    private var isIdle: () -> Bool
    private var waitForIdle: () async -> Void
    private var abort: () -> Void
    private var hasPendingMessages: () -> Bool
    private var newSessionHandler: HookNewSessionHandler
    private var branchHandler: HookBranchHandler
    private var navigateTreeHandler: HookNavigateTreeHandler
    private var uiContext: HookUIContext
    private var hasUI: Bool
    private var errorListeners: [UUID: (HookError) -> Void]

    public init(_ hooks: [LoadedHook], _ cwd: String, _ sessionManager: SessionManager, _ modelRegistry: ModelRegistry) {
        self.hooks = hooks
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.getModel = { nil }
        self.isIdle = { true }
        self.waitForIdle = {}
        self.abort = {}
        self.hasPendingMessages = { false }
        self.newSessionHandler = { _ in HookCommandResult(cancelled: false) }
        self.branchHandler = { _ in HookCommandResult(cancelled: false) }
        self.navigateTreeHandler = { _, _ in HookCommandResult(cancelled: false) }
        self.uiContext = NoOpHookUIContext()
        self.hasUI = false
        self.errorListeners = [:]
    }

    public func initialize(
        getModel: @escaping () -> Model?,
        sendMessageHandler: @escaping HookSendMessageHandler = { _, _ in },
        appendEntryHandler: @escaping HookAppendEntryHandler = { _, _ in },
        newSessionHandler: HookNewSessionHandler? = nil,
        branchHandler: HookBranchHandler? = nil,
        navigateTreeHandler: HookNavigateTreeHandler? = nil,
        isIdle: (() -> Bool)? = nil,
        waitForIdle: (() async -> Void)? = nil,
        abort: (() -> Void)? = nil,
        hasPendingMessages: (() -> Bool)? = nil,
        uiContext: HookUIContext? = nil,
        hasUI: Bool = false
    ) {
        self.getModel = getModel
        self.isIdle = isIdle ?? { true }
        self.waitForIdle = waitForIdle ?? {}
        self.abort = abort ?? {}
        self.hasPendingMessages = hasPendingMessages ?? { false }
        if let newSessionHandler {
            self.newSessionHandler = newSessionHandler
        }
        if let branchHandler {
            self.branchHandler = branchHandler
        }
        if let navigateTreeHandler {
            self.navigateTreeHandler = navigateTreeHandler
        }
        self.uiContext = uiContext ?? NoOpHookUIContext()
        self.hasUI = hasUI

        for hook in hooks {
            hook.setSendMessageHandler(sendMessageHandler)
            hook.setAppendEntryHandler(appendEntryHandler)
        }
    }

    public func getUIContext() -> HookUIContext {
        uiContext
    }

    public func getHasUI() -> Bool {
        hasUI
    }

    public func getHookPaths() -> [String] {
        hooks.map { $0.path }
    }

    public func getMessageRenderer(_ customType: String) -> HookMessageRenderer? {
        for hook in hooks {
            if let renderer = hook.messageRenderers[customType] {
                return renderer
            }
        }
        return nil
    }

    public func getRegisteredCommands() -> [RegisteredCommand] {
        var commands: [RegisteredCommand] = []
        for hook in hooks {
            commands.append(contentsOf: hook.commands.values)
        }
        return commands
    }

    public func getCommand(_ name: String) -> RegisteredCommand? {
        for hook in hooks {
            if let command = hook.commands[name] {
                return command
            }
        }
        return nil
    }

    public func onError(_ listener: @escaping (HookError) -> Void) -> () -> Void {
        let id = UUID()
        errorListeners[id] = listener
        return { [weak self] in
            self?.errorListeners[id] = nil
        }
    }

    public func emitError(_ error: HookError) {
        for listener in errorListeners.values {
            listener(error)
        }
    }

    public func hasHandlers(_ type: String) -> Bool {
        for hook in hooks {
            if let handlers = hook.handlers[type], !handlers.isEmpty {
                return true
            }
        }
        return false
    }

    private func createContext() -> HookContext {
        HookContext(
            ui: uiContext,
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: getModel(),
            isIdle: { [weak self] in self?.isIdle() ?? true },
            abort: { [weak self] in self?.abort() },
            hasPendingMessages: { [weak self] in self?.hasPendingMessages() ?? false }
        )
    }

    public func createCommandContext() -> HookCommandContext {
        HookCommandContext(
            ui: uiContext,
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: getModel(),
            isIdle: { [weak self] in self?.isIdle() ?? true },
            abort: { [weak self] in self?.abort() },
            hasPendingMessages: { [weak self] in self?.hasPendingMessages() ?? false },
            waitForIdle: { [weak self] in await self?.waitForIdle() },
            newSession: { [weak self] options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.newSessionHandler(options)
            },
            branch: { [weak self] entryId in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.branchHandler(entryId)
            },
            navigateTree: { [weak self] targetId, options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.navigateTreeHandler(targetId, options)
            }
        )
    }

    public func emit(_ event: HookEvent) async -> Any? {
        let context = createContext()
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
                        if let result = result as? SessionBeforeSwitchResult, result.cancel {
                            return result
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription))
                }
            }
        }

        return lastResult
    }

    public func emitToolCall(_ event: ToolCallEvent) async -> ToolCallEventResult? {
        let context = createContext()
        var lastResult: ToolCallEventResult? = nil

        for hook in hooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(event, context) as? ToolCallEventResult {
                        lastResult = result
                        if result.block {
                            return result
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription))
                }
            }
        }

        return lastResult
    }

    public func emitContext(_ messages: [AgentMessage], signal: CancellationToken? = nil) async -> [AgentMessage] {
        _ = signal
        let context = createContext()
        var currentMessages = messages

        for hook in hooks {
            guard let handlers = hook.handlers["context"] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(ContextEvent(messages: currentMessages), context) as? ContextEventResult,
                       let replacement = result.messages {
                        currentMessages = replacement
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: "context", error: error.localizedDescription))
                }
            }
        }

        return currentMessages
    }

    public func emitBeforeAgentStart(_ prompt: String, _ images: [ImageContent]?) async -> BeforeAgentStartEventResult? {
        let context = createContext()
        var result: BeforeAgentStartEventResult?

        for hook in hooks {
            guard let handlers = hook.handlers["before_agent_start"] else { continue }
            for handler in handlers {
                do {
                    if let handlerResult = try await handler(BeforeAgentStartEvent(prompt: prompt, images: images), context) as? BeforeAgentStartEventResult {
                        if result == nil, handlerResult.message != nil {
                            result = handlerResult
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: "before_agent_start", error: error.localizedDescription))
                }
            }
        }

        return result
    }
}
