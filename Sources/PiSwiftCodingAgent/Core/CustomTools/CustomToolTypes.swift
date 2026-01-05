import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent

public typealias CustomToolUIContext = HookUIContext
public typealias CustomToolResult = AgentToolResult
public typealias CustomToolUpdateCallback = AgentToolUpdateCallback

public struct CustomToolContext: Sendable {
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var isIdle: @Sendable () -> Bool
    public var hasPendingMessages: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var events: EventBus
    public var sendMessage: HookSendMessageHandler

    public init(
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: Model?,
        isIdle: @escaping @Sendable () -> Bool,
        hasPendingMessages: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        events: EventBus,
        sendMessage: @escaping HookSendMessageHandler
    ) {
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.isIdle = isIdle
        self.hasPendingMessages = hasPendingMessages
        self.abort = abort
        self.events = events
        self.sendMessage = sendMessage
    }
}

public struct CustomToolSessionEvent: Sendable {
    public enum Reason: String, Sendable {
        case start
        case `switch`
        case branch
        case tree
        case shutdown
    }

    public var reason: Reason
    public var previousSessionFile: String?

    public init(reason: Reason, previousSessionFile: String?) {
        self.reason = reason
        self.previousSessionFile = previousSessionFile
    }
}

public struct RenderResultOptions: Sendable {
    public var expanded: Bool
    public var isPartial: Bool

    public init(expanded: Bool, isPartial: Bool) {
        self.expanded = expanded
        self.isPartial = isPartial
    }
}

public typealias CustomToolExecute = @Sendable (
    _ toolCallId: String,
    _ params: [String: AnyCodable],
    _ onUpdate: CustomToolUpdateCallback?,
    _ context: CustomToolContext,
    _ signal: CancellationToken?
) async throws -> CustomToolResult

public typealias CustomToolSessionHandler = @Sendable (_ event: CustomToolSessionEvent, _ context: CustomToolContext) async throws -> Void
public typealias CustomToolRenderCall = @Sendable (_ args: [String: AnyCodable], _ theme: Theme) throws -> Component?
public typealias CustomToolRenderResult = @Sendable (_ result: CustomToolResult, _ options: RenderResultOptions, _ theme: Theme) throws -> Component?

public struct CustomTool: @unchecked Sendable {
    public var name: String
    public var label: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var execute: CustomToolExecute
    public var onSession: CustomToolSessionHandler?
    public var renderCall: CustomToolRenderCall?
    public var renderResult: CustomToolRenderResult?

    public init(
        name: String,
        label: String,
        description: String,
        parameters: [String: AnyCodable],
        execute: @escaping CustomToolExecute,
        onSession: CustomToolSessionHandler? = nil,
        renderCall: CustomToolRenderCall? = nil,
        renderResult: CustomToolRenderResult? = nil
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.execute = execute
        self.onSession = onSession
        self.renderCall = renderCall
        self.renderResult = renderResult
    }
}

public struct CustomToolDefinition: Sendable {
    public var path: String?
    public var tool: CustomTool

    public init(path: String? = nil, tool: CustomTool) {
        self.path = path
        self.tool = tool
    }
}

public struct LoadedCustomTool: Sendable {
    public var path: String
    public var resolvedPath: String
    public var tool: CustomTool

    public init(path: String, resolvedPath: String, tool: CustomTool) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.tool = tool
    }
}

public struct CustomToolLoadError: Sendable {
    public var path: String
    public var error: String

    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

public struct CustomToolsLoadResult: @unchecked Sendable {
    public var tools: [LoadedCustomTool]
    public var errors: [CustomToolLoadError]
    public var setUIContext: (@Sendable (_ uiContext: CustomToolUIContext, _ hasUI: Bool) -> Void)
    public var setSendMessageHandler: (@Sendable (_ handler: @escaping HookSendMessageHandler) -> Void)

    public init(
        tools: [LoadedCustomTool],
        errors: [CustomToolLoadError],
        setUIContext: @escaping @Sendable (_ uiContext: CustomToolUIContext, _ hasUI: Bool) -> Void = { _, _ in },
        setSendMessageHandler: @escaping @Sendable (_ handler: @escaping HookSendMessageHandler) -> Void = { _ in }
    ) {
        self.tools = tools
        self.errors = errors
        self.setUIContext = setUIContext
        self.setSendMessageHandler = setSendMessageHandler
    }
}

public protocol CustomToolPlugin: AnyObject {
    init()
    func register(_ api: CustomToolAPI)
}

public final class CustomToolAPI: @unchecked Sendable {
    public let cwd: String
    public let events: EventBus

    private let lock = NSLock()
    private var uiContext: CustomToolUIContext
    private var hasUIValue: Bool
    private var registeredTools: [CustomTool] = []
    private var sendMessageHandler: HookSendMessageHandler = { _, _ in }

    public init(
        cwd: String,
        events: EventBus,
        ui: CustomToolUIContext = NoOpHookUIContext(),
        hasUI: Bool = false
    ) {
        self.cwd = cwd
        self.events = events
        self.uiContext = ui
        self.hasUIValue = hasUI
    }

    public var ui: CustomToolUIContext {
        get {
            lock.lock()
            defer { lock.unlock() }
            return uiContext
        }
        set {
            lock.lock()
            uiContext = newValue
            lock.unlock()
        }
    }

    public var hasUI: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hasUIValue
        }
        set {
            lock.lock()
            hasUIValue = newValue
            lock.unlock()
        }
    }

    public func register(_ tool: CustomTool) {
        lock.lock()
        registeredTools.append(tool)
        lock.unlock()
    }

    public func register(_ tools: [CustomTool]) {
        lock.lock()
        registeredTools.append(contentsOf: tools)
        lock.unlock()
    }

    public func toolsSnapshot() -> [CustomTool] {
        lock.lock()
        let snapshot = registeredTools
        lock.unlock()
        return snapshot
    }

    public func setSendMessageHandler(_ handler: @escaping HookSendMessageHandler) {
        lock.lock()
        sendMessageHandler = handler
        lock.unlock()
    }

    public func sendMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) {
        lock.lock()
        let handler = sendMessageHandler
        lock.unlock()
        handler(message, options)
    }

    public func exec(_ command: String, _ args: [String], _ options: ExecOptions? = nil) async -> ExecResult {
        let execCwd = options?.cwd ?? cwd
        return await execCommand(command, args, execCwd, options)
    }
}
