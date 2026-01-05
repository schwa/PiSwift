import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent

public enum HookNotificationType: String, Sendable {
    case info
    case warning
    case error
}

public enum HookFlagType: String, Sendable {
    case boolean
    case string
}

public enum HookFlagValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string:
            return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .bool:
            return nil
        case .string(let value):
            return value
        }
    }
}

public struct HookFlag: Sendable {
    public var name: String
    public var hookPath: String
    public var description: String?
    public var type: HookFlagType
    public var defaultValue: HookFlagValue?

    public init(
        name: String,
        hookPath: String,
        description: String? = nil,
        type: HookFlagType,
        defaultValue: HookFlagValue? = nil
    ) {
        self.name = name
        self.hookPath = hookPath
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
    }
}

public struct HookFlagOptions: Sendable {
    public var description: String?
    public var type: HookFlagType
    public var defaultValue: HookFlagValue?

    public init(description: String? = nil, type: HookFlagType, defaultValue: HookFlagValue? = nil) {
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
    }
}

public typealias HookWidgetFactory = @Sendable (_ tui: TUI, _ theme: Theme) -> Component

public enum HookWidgetContent: @unchecked Sendable {
    case lines([String])
    case component(HookWidgetFactory)
}

public struct HookMessageRenderOptions: Sendable {
    public var expanded: Bool

    public init(expanded: Bool) {
        self.expanded = expanded
    }
}

public typealias HookMessageRenderer = @Sendable (HookMessage, HookMessageRenderOptions, Theme) -> Component?

public enum HookDeliverAs: String, Sendable {
    case steer
    case followUp
    case nextTurn
}

public struct HookSendMessageOptions: Sendable {
    public var triggerTurn: Bool
    public var deliverAs: HookDeliverAs?

    public init(triggerTurn: Bool = false, deliverAs: HookDeliverAs? = nil) {
        self.triggerTurn = triggerTurn
        self.deliverAs = deliverAs
    }
}

public struct HookMessageInput: Sendable {
    public var customType: String
    public var content: HookMessageContent
    public var display: Bool
    public var details: AnyCodable?

    public init(customType: String, content: HookMessageContent, display: Bool, details: AnyCodable? = nil) {
        self.customType = customType
        self.content = content
        self.display = display
        self.details = details
    }
}

public typealias HookSendMessageHandler = @Sendable (_ message: HookMessageInput, _ options: HookSendMessageOptions?) -> Void
public typealias HookAppendEntryHandler = @Sendable (_ customType: String, _ data: [String: Any]) -> Void
public typealias HookSendMessageSetter = (@escaping HookSendMessageHandler) -> Void
public typealias HookAppendEntrySetter = (@escaping HookAppendEntryHandler) -> Void
public typealias HookGetActiveToolsHandler = @Sendable () -> [String]
public typealias HookGetAllToolsHandler = @Sendable () -> [String]
public typealias HookSetActiveToolsHandler = @Sendable (_ toolNames: [String]) -> Void
public typealias HookGetActiveToolsSetter = (@escaping HookGetActiveToolsHandler) -> Void
public typealias HookGetAllToolsSetter = (@escaping HookGetAllToolsHandler) -> Void
public typealias HookSetActiveToolsSetter = (@escaping HookSetActiveToolsHandler) -> Void
public typealias HookSetFlagValue = @Sendable (_ name: String, _ value: HookFlagValue) -> Void

public struct HookCommandResult: Sendable {
    public var cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

public struct HookNewSessionOptions: Sendable {
    public var parentSession: String?
    public var setup: (@Sendable (SessionManager) async -> Void)?

    public init(parentSession: String? = nil, setup: (@Sendable (SessionManager) async -> Void)? = nil) {
        self.parentSession = parentSession
        self.setup = setup
    }
}

public struct HookNavigateTreeOptions: Sendable {
    public var summarize: Bool

    public init(summarize: Bool = false) {
        self.summarize = summarize
    }
}

public typealias HookNewSessionHandler = @Sendable (_ options: HookNewSessionOptions?) async -> HookCommandResult
public typealias HookBranchHandler = @Sendable (_ entryId: String) async -> HookCommandResult
public typealias HookNavigateTreeHandler = @Sendable (_ targetId: String, _ options: HookNavigateTreeOptions?) async -> HookCommandResult

public struct RegisteredCommand: Sendable {
    public var name: String
    public var description: String?
    public var handler: @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void

    public init(name: String, description: String? = nil, handler: @escaping @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void) {
        self.name = name
        self.description = description
        self.handler = handler
    }
}

public protocol HookDisposableComponent: Component {
    func dispose()
}

public struct HookCustomResult: @unchecked Sendable {
    public var value: Any?

    public init(_ value: Any?) {
        self.value = value
    }
}

public typealias HookCustomClose = @MainActor @Sendable (Any?) -> Void
public typealias HookCustomFactory = @Sendable (_ tui: TUI, _ theme: Theme, _ done: @escaping HookCustomClose) async -> Component

@MainActor
public protocol HookUIContext: Sendable {
    func select(_ title: String, _ options: [String]) async -> String?
    func confirm(_ title: String, _ message: String) async -> Bool
    func input(_ title: String, _ placeholder: String?) async -> String?
    func notify(_ message: String, _ type: HookNotificationType?)
    func setStatus(_ key: String, _ text: String?)
    func setWidget(_ key: String, _ content: HookWidgetContent?)
    func setTitle(_ title: String)
    func custom(_ factory: @escaping HookCustomFactory) async -> HookCustomResult?
    func setEditorText(_ text: String)
    func getEditorText() -> String
    func editor(_ title: String, _ prefill: String?) async -> String?
    var theme: Theme { get }
}

public extension HookUIContext {
    func setWidget(_ key: String, _ lines: [String]) {
        setWidget(key, .lines(lines))
    }

    func setWidget(_ key: String, _ factory: @escaping HookWidgetFactory) {
        setWidget(key, .component(factory))
    }
}

public final class NoOpHookUIContext: HookUIContext {
    public nonisolated init() {}

    public func select(_ title: String, _ options: [String]) async -> String? { nil }
    public func confirm(_ title: String, _ message: String) async -> Bool { false }
    public func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    public func notify(_ message: String, _ type: HookNotificationType?) {}
    public func setStatus(_ key: String, _ text: String?) {}
    public func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    public func setTitle(_ title: String) {}
    public func custom(_ factory: @escaping HookCustomFactory) async -> HookCustomResult? { nil }
    public func setEditorText(_ text: String) {}
    public func getEditorText() -> String { "" }
    public func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    public var theme: Theme { Theme.fallback() }
}

public struct HookContext: Sendable {
    public var ui: HookUIContext
    public var hasUI: Bool
    public var cwd: String
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var isIdle: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var hasPendingMessages: @Sendable () -> Bool

    public init(
        ui: HookUIContext,
        hasUI: Bool,
        cwd: String,
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: Model?,
        isIdle: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        hasPendingMessages: @escaping @Sendable () -> Bool
    ) {
        self.ui = ui
        self.hasUI = hasUI
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.isIdle = isIdle
        self.abort = abort
        self.hasPendingMessages = hasPendingMessages
    }

    public init(sessionManager: SessionManager, modelRegistry: ModelRegistry, model: Model?, hasUI: Bool) {
        self.init(
            ui: NoOpHookUIContext(),
            hasUI: hasUI,
            cwd: FileManager.default.currentDirectoryPath,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: model,
            isIdle: { true },
            abort: {},
            hasPendingMessages: { false }
        )
    }
}

public struct HookCommandContext: Sendable {
    public var ui: HookUIContext
    public var hasUI: Bool
    public var cwd: String
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var isIdle: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var hasPendingMessages: @Sendable () -> Bool
    public var waitForIdle: @Sendable () async -> Void
    public var newSession: HookNewSessionHandler
    public var branch: HookBranchHandler
    public var navigateTree: HookNavigateTreeHandler

    public init(
        ui: HookUIContext,
        hasUI: Bool,
        cwd: String,
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: Model?,
        isIdle: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        hasPendingMessages: @escaping @Sendable () -> Bool,
        waitForIdle: @escaping @Sendable () async -> Void,
        newSession: @escaping HookNewSessionHandler,
        branch: @escaping HookBranchHandler,
        navigateTree: @escaping HookNavigateTreeHandler
    ) {
        self.ui = ui
        self.hasUI = hasUI
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.isIdle = isIdle
        self.abort = abort
        self.hasPendingMessages = hasPendingMessages
        self.waitForIdle = waitForIdle
        self.newSession = newSession
        self.branch = branch
        self.navigateTree = navigateTree
    }
}

public struct HookShortcut: Sendable {
    public var shortcut: KeyId
    public var hookPath: String
    public var description: String?
    public var handler: @Sendable (_ context: HookContext) async -> Void

    public init(
        shortcut: KeyId,
        hookPath: String,
        description: String? = nil,
        handler: @escaping @Sendable (_ context: HookContext) async -> Void
    ) {
        self.shortcut = shortcut
        self.hookPath = hookPath
        self.description = description
        self.handler = handler
    }
}

public protocol HookEvent: Sendable {
    var type: String { get }
}

public enum SessionSwitchReason: String, Sendable {
    case new
    case resume
}

public struct SessionStartEvent: HookEvent, Sendable {
    public let type: String = "session_start"

    public init() {}
}

public struct SessionBeforeSwitchEvent: HookEvent, Sendable {
    public let type: String = "session_before_switch"
    public var reason: SessionSwitchReason
    public var targetSessionFile: String?

    public init(reason: SessionSwitchReason, targetSessionFile: String? = nil) {
        self.reason = reason
        self.targetSessionFile = targetSessionFile
    }
}

public struct SessionSwitchEvent: HookEvent, Sendable {
    public let type: String = "session_switch"
    public var reason: SessionSwitchReason
    public var previousSessionFile: String?

    public init(reason: SessionSwitchReason, previousSessionFile: String?) {
        self.reason = reason
        self.previousSessionFile = previousSessionFile
    }
}

public struct SessionShutdownEvent: HookEvent, Sendable {
    public let type: String = "session_shutdown"

    public init() {}
}

public struct ContextEvent: HookEvent, Sendable {
    public let type: String = "context"
    public var messages: [AgentMessage]

    public init(messages: [AgentMessage]) {
        self.messages = messages
    }
}

public struct BeforeAgentStartEvent: HookEvent, Sendable {
    public let type: String = "before_agent_start"
    public var prompt: String
    public var images: [ImageContent]?

    public init(prompt: String, images: [ImageContent]?) {
        self.prompt = prompt
        self.images = images
    }
}

public struct AgentStartEvent: HookEvent, Sendable {
    public let type: String = "agent_start"

    public init() {}
}

public struct AgentEndEvent: HookEvent, Sendable {
    public let type: String = "agent_end"
    public var messages: [AgentMessage]

    public init(messages: [AgentMessage]) {
        self.messages = messages
    }
}

public struct TurnStartEvent: HookEvent, Sendable {
    public let type: String = "turn_start"
    public var turnIndex: Int
    public var timestamp: Int64

    public init(turnIndex: Int, timestamp: Int64) {
        self.turnIndex = turnIndex
        self.timestamp = timestamp
    }
}

public struct TurnEndEvent: HookEvent, Sendable {
    public let type: String = "turn_end"
    public var turnIndex: Int
    public var message: AgentMessage
    public var toolResults: [ToolResultMessage]

    public init(turnIndex: Int, message: AgentMessage, toolResults: [ToolResultMessage]) {
        self.turnIndex = turnIndex
        self.message = message
        self.toolResults = toolResults
    }
}

public struct SessionBeforeCompactEvent: HookEvent, Sendable {
    public let type: String = "session_before_compact"
    public var preparation: CompactionPreparation
    public var branchEntries: [SessionEntry]
    public var customInstructions: String?
    public var signal: CancellationToken?

    public init(preparation: CompactionPreparation, branchEntries: [SessionEntry], customInstructions: String?, signal: CancellationToken?) {
        self.preparation = preparation
        self.branchEntries = branchEntries
        self.customInstructions = customInstructions
        self.signal = signal
    }
}

public struct SessionCompactEvent: HookEvent, Sendable {
    public let type: String = "session_compact"
    public var compactionEntry: CompactionEntry
    public var fromHook: Bool

    public init(compactionEntry: CompactionEntry, fromHook: Bool) {
        self.compactionEntry = compactionEntry
        self.fromHook = fromHook
    }
}

public struct SessionBeforeBranchEvent: HookEvent, Sendable {
    public let type: String = "session_before_branch"
    public var entryId: String

    public init(entryId: String) {
        self.entryId = entryId
    }
}

public struct SessionBranchEvent: HookEvent, Sendable {
    public let type: String = "session_branch"
    public var previousSessionFile: String?

    public init(previousSessionFile: String?) {
        self.previousSessionFile = previousSessionFile
    }
}

public struct SessionBeforeTreeEvent: HookEvent, Sendable {
    public let type: String = "session_before_tree"
    public var preparation: TreePreparation
    public var signal: CancellationToken?

    public init(preparation: TreePreparation, signal: CancellationToken?) {
        self.preparation = preparation
        self.signal = signal
    }
}

public struct SessionTreeEvent: HookEvent, Sendable {
    public let type: String = "session_tree"
    public var newLeafId: String?
    public var oldLeafId: String?
    public var summaryEntry: BranchSummaryEntry?
    public var fromHook: Bool?

    public init(newLeafId: String?, oldLeafId: String?, summaryEntry: BranchSummaryEntry?, fromHook: Bool?) {
        self.newLeafId = newLeafId
        self.oldLeafId = oldLeafId
        self.summaryEntry = summaryEntry
        self.fromHook = fromHook
    }
}

public struct ToolCallEvent: HookEvent, Sendable {
    public let type: String = "tool_call"
    public var toolName: String
    public var toolCallId: String
    public var input: [String: AnyCodable]

    public init(toolName: String, toolCallId: String, input: [String: AnyCodable]) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.input = input
    }
}

public struct ToolCallEventResult: Sendable {
    public var block: Bool
    public var reason: String?

    public init(block: Bool = false, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

public struct ToolResultEvent: HookEvent, Sendable {
    public let type: String = "tool_result"
    public var toolName: String
    public var toolCallId: String
    public var input: [String: AnyCodable]
    public var content: [ContentBlock]
    public var details: AnyCodable?
    public var isError: Bool

    public init(
        toolName: String,
        toolCallId: String,
        input: [String: AnyCodable],
        content: [ContentBlock],
        details: AnyCodable?,
        isError: Bool
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.input = input
        self.content = content
        self.details = details
        self.isError = isError
    }
}

public struct ToolResultEventResult: Sendable {
    public var content: [ContentBlock]?
    public var details: AnyCodable?

    public init(content: [ContentBlock]? = nil, details: AnyCodable? = nil) {
        self.content = content
        self.details = details
    }
}

public struct SessionBeforeCompactResult: Sendable {
    public var cancel: Bool
    public var compaction: CompactionResult?

    public init(cancel: Bool = false, compaction: CompactionResult? = nil) {
        self.cancel = cancel
        self.compaction = compaction
    }
}

public struct BeforeAgentStartEventResult: Sendable {
    public var message: HookMessageInput?
    public var systemPromptAppend: String?

    public init(message: HookMessageInput? = nil, systemPromptAppend: String? = nil) {
        self.message = message
        self.systemPromptAppend = systemPromptAppend
    }
}

public struct BeforeAgentStartCombinedResult: Sendable {
    public var messages: [HookMessageInput]?
    public var systemPromptAppend: String?

    public init(messages: [HookMessageInput]? = nil, systemPromptAppend: String? = nil) {
        self.messages = messages
        self.systemPromptAppend = systemPromptAppend
    }
}

public struct SessionBeforeSwitchResult: Sendable {
    public var cancel: Bool

    public init(cancel: Bool = false) {
        self.cancel = cancel
    }
}

public struct SessionBeforeBranchResult: Sendable {
    public var cancel: Bool
    public var skipConversationRestore: Bool

    public init(cancel: Bool = false, skipConversationRestore: Bool = false) {
        self.cancel = cancel
        self.skipConversationRestore = skipConversationRestore
    }
}

public struct SessionBeforeTreeResult: Sendable {
    public var cancel: Bool
    public var summary: BranchSummaryResult?

    public init(cancel: Bool = false, summary: BranchSummaryResult? = nil) {
        self.cancel = cancel
        self.summary = summary
    }
}

public struct ContextEventResult: Sendable {
    public var messages: [AgentMessage]?

    public init(messages: [AgentMessage]? = nil) {
        self.messages = messages
    }
}

public typealias HookHandler = @Sendable (_ event: HookEvent, _ context: HookContext) async throws -> Any?

public struct HookError: Sendable {
    public var hookPath: String
    public var event: String
    public var error: String
    public var stack: String?

    public init(hookPath: String, event: String, error: String, stack: String? = nil) {
        self.hookPath = hookPath
        self.event = event
        self.error = error
        self.stack = stack
    }
}

public struct LoadedHook: @unchecked Sendable {
    public var path: String
    public var resolvedPath: String
    public var handlers: [String: [HookHandler]]
    public var messageRenderers: [String: HookMessageRenderer]
    public var commands: [String: RegisteredCommand]
    public var flags: [String: HookFlag]
    public var shortcuts: [KeyId: HookShortcut]
    public var setSendMessageHandler: HookSendMessageSetter
    public var setAppendEntryHandler: HookAppendEntrySetter
    public var setGetActiveToolsHandler: HookGetActiveToolsSetter
    public var setGetAllToolsHandler: HookGetAllToolsSetter
    public var setSetActiveToolsHandler: HookSetActiveToolsSetter
    public var setFlagValue: HookSetFlagValue

    public init(
        path: String,
        resolvedPath: String,
        handlers: [String: [HookHandler]],
        messageRenderers: [String: HookMessageRenderer] = [:],
        commands: [String: RegisteredCommand] = [:],
        flags: [String: HookFlag] = [:],
        shortcuts: [KeyId: HookShortcut] = [:],
        setSendMessageHandler: @escaping HookSendMessageSetter = { _ in },
        setAppendEntryHandler: @escaping HookAppendEntrySetter = { _ in },
        setGetActiveToolsHandler: @escaping HookGetActiveToolsSetter = { _ in },
        setGetAllToolsHandler: @escaping HookGetAllToolsSetter = { _ in },
        setSetActiveToolsHandler: @escaping HookSetActiveToolsSetter = { _ in },
        setFlagValue: @escaping HookSetFlagValue = { _, _ in }
    ) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.handlers = handlers
        self.messageRenderers = messageRenderers
        self.commands = commands
        self.flags = flags
        self.shortcuts = shortcuts
        self.setSendMessageHandler = setSendMessageHandler
        self.setAppendEntryHandler = setAppendEntryHandler
        self.setGetActiveToolsHandler = setGetActiveToolsHandler
        self.setGetAllToolsHandler = setGetAllToolsHandler
        self.setSetActiveToolsHandler = setSetActiveToolsHandler
        self.setFlagValue = setFlagValue
    }
}

public struct TreePreparation: Sendable {
    public var targetId: String
    public var oldLeafId: String?
    public var commonAncestorId: String?
    public var entriesToSummarize: [SessionEntry]
    public var userWantsSummary: Bool

    public init(targetId: String, oldLeafId: String?, commonAncestorId: String?, entriesToSummarize: [SessionEntry], userWantsSummary: Bool) {
        self.targetId = targetId
        self.oldLeafId = oldLeafId
        self.commonAncestorId = commonAncestorId
        self.entriesToSummarize = entriesToSummarize
        self.userWantsSummary = userWantsSummary
    }
}

public final class HookAPI: @unchecked Sendable {
    public let events: EventBus
    public private(set) var handlers: [String: [HookHandler]] = [:]
    public private(set) var messageRenderers: [String: HookMessageRenderer] = [:]
    public private(set) var commands: [String: RegisteredCommand] = [:]
    public private(set) var flags: [String: HookFlag] = [:]
    public private(set) var shortcuts: [KeyId: HookShortcut] = [:]
    private var sendMessageHandler: HookSendMessageHandler = { _, _ in }
    private var appendEntryHandler: HookAppendEntryHandler = { _, _ in }
    private var getActiveToolsHandler: HookGetActiveToolsHandler = { [] }
    private var getAllToolsHandler: HookGetAllToolsHandler = { [] }
    private var setActiveToolsHandler: HookSetActiveToolsHandler = { _ in }
    private var flagValues: [String: HookFlagValue] = [:]
    private var execCwd: String?
    private var hookPath: String = "<hook>"

    public init(events: EventBus = createEventBus(), hookPath: String? = nil) {
        self.events = events
        if let hookPath {
            self.hookPath = hookPath
        }
    }

    public func setExecCwd(_ cwd: String) {
        execCwd = cwd
    }

    public func setHookPath(_ path: String) {
        hookPath = path
    }

    public func setSendMessageHandler(_ handler: @escaping HookSendMessageHandler) {
        sendMessageHandler = handler
    }

    public func setAppendEntryHandler(_ handler: @escaping HookAppendEntryHandler) {
        appendEntryHandler = handler
    }

    public func setGetActiveToolsHandler(_ handler: @escaping HookGetActiveToolsHandler) {
        getActiveToolsHandler = handler
    }

    public func setGetAllToolsHandler(_ handler: @escaping HookGetAllToolsHandler) {
        getAllToolsHandler = handler
    }

    public func setSetActiveToolsHandler(_ handler: @escaping HookSetActiveToolsHandler) {
        setActiveToolsHandler = handler
    }

    public func setFlagValue(_ name: String, _ value: HookFlagValue) {
        flagValues[name] = value
    }

    public func on<T: HookEvent>(_ type: String, _ handler: @Sendable @escaping (T, HookContext) async throws -> Any?) {
        let wrapper: HookHandler = { event, context in
            guard let typed = event as? T else { return nil }
            return try await handler(typed, context)
        }
        handlers[type, default: []].append(wrapper)
    }

    public func onAny(_ type: String, _ handler: @Sendable @escaping (HookEvent, HookContext) async throws -> Any?) {
        handlers[type, default: []].append(handler)
    }

    public func sendMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) {
        sendMessageHandler(message, options)
    }

    public func appendEntry(_ customType: String, _ data: [String: Any]) {
        appendEntryHandler(customType, data)
    }

    public func getActiveTools() -> [String] {
        getActiveToolsHandler()
    }

    public func getAllTools() -> [String] {
        getAllToolsHandler()
    }

    public func setActiveTools(_ toolNames: [String]) {
        setActiveToolsHandler(toolNames)
    }

    public func registerFlag(_ name: String, _ options: HookFlagOptions) {
        let flag = HookFlag(
            name: name,
            hookPath: hookPath,
            description: options.description,
            type: options.type,
            defaultValue: options.defaultValue
        )
        flags[name] = flag
        if let defaultValue = options.defaultValue {
            flagValues[name] = defaultValue
        }
    }

    public func getFlag(_ name: String) -> HookFlagValue? {
        flagValues[name]
    }

    public func registerShortcut(_ shortcut: KeyId, description: String? = nil, handler: @escaping @Sendable (_ context: HookContext) async -> Void) {
        shortcuts[shortcut] = HookShortcut(
            shortcut: shortcut,
            hookPath: hookPath,
            description: description,
            handler: handler
        )
    }

    public func registerMessageRenderer(_ customType: String, _ renderer: @escaping HookMessageRenderer) {
        messageRenderers[customType] = renderer
    }

    public func registerCommand(_ name: String, description: String? = nil, handler: @escaping @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void) {
        commands[name] = RegisteredCommand(name: name, description: description, handler: handler)
    }

    public func exec(_ command: String, _ args: [String], _ options: ExecOptions? = nil) async -> ExecResult {
        let cwd = options?.cwd ?? execCwd ?? FileManager.default.currentDirectoryPath
        return await execCommand(command, args, cwd, options)
    }
}
