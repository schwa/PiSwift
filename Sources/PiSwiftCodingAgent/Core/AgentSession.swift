import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum AutoCompactionReason: String, Sendable {
    case threshold
    case overflow
}

public enum AgentSessionEvent: Sendable {
    case agent(AgentEvent)
    case autoCompactionStart(reason: AutoCompactionReason)
    case autoCompactionEnd(result: CompactionResult?, aborted: Bool, willRetry: Bool)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)

    public var type: String {
        switch self {
        case .agent(let event):
            return event.type
        case .autoCompactionStart:
            return "auto_compaction_start"
        case .autoCompactionEnd:
            return "auto_compaction_end"
        case .autoRetryStart:
            return "auto_retry_start"
        case .autoRetryEnd:
            return "auto_retry_end"
        }
    }
}

public struct AgentSessionConfig: Sendable {
    public var agent: Agent
    public var sessionManager: SessionManager
    public var settingsManager: SettingsManager
    public var scopedModels: [ScopedModel]?
    public var fileCommands: [FileSlashCommand]?
    public var hookRunner: HookRunner?
    public var customTools: [LoadedCustomTool]?
    public var modelRegistry: ModelRegistry
    public var skillsSettings: SkillsSettings?

    public init(
        agent: Agent,
        sessionManager: SessionManager,
        settingsManager: SettingsManager,
        scopedModels: [ScopedModel]? = nil,
        fileCommands: [FileSlashCommand]? = nil,
        hookRunner: HookRunner? = nil,
        customTools: [LoadedCustomTool]? = nil,
        modelRegistry: ModelRegistry,
        skillsSettings: SkillsSettings? = nil
    ) {
        self.agent = agent
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
        self.scopedModels = scopedModels
        self.fileCommands = fileCommands
        self.hookRunner = hookRunner
        self.customTools = customTools
        self.modelRegistry = modelRegistry
        self.skillsSettings = skillsSettings
    }
}

public struct PromptOptions: Sendable {
    public var expandSlashCommands: Bool?
    public var images: [ImageContent]?

    public init(expandSlashCommands: Bool? = nil, images: [ImageContent]? = nil) {
        self.expandSlashCommands = expandSlashCommands
        self.images = images
    }
}

public struct BranchableMessage: Sendable {
    public var entryId: String
    public var text: String

    public init(entryId: String, text: String) {
        self.entryId = entryId
        self.text = text
    }
}

public struct SessionStats: Sendable {
    public var sessionFile: String?
    public var sessionId: String
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var toolResults: Int
    public var totalMessages: Int
    public var tokens: TokenStats
    public var cost: Double

    public struct TokenStats: Sendable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int

        public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = total
        }
    }

    public init(
        sessionFile: String?,
        sessionId: String,
        userMessages: Int,
        assistantMessages: Int,
        toolCalls: Int,
        toolResults: Int,
        totalMessages: Int,
        tokens: TokenStats,
        cost: Double
    ) {
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.totalMessages = totalMessages
        self.tokens = tokens
        self.cost = cost
    }
}

public enum ModelCycleDirection: String, Sendable {
    case forward
    case backward
}

public struct ModelCycleResult: Sendable {
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var isScoped: Bool

    public init(model: Model, thinkingLevel: ThinkingLevel, isScoped: Bool) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.isScoped = isScoped
    }
}

public final class AgentSession: @unchecked Sendable {
    public let agent: Agent
    public let sessionManager: SessionManager
    public let settingsManager: SettingsManager
    public let modelRegistry: ModelRegistry
    private var _hookRunner: HookRunner?
    private var customToolsInternal: [LoadedCustomTool]
    private var scopedModels: [ScopedModel]
    private var fileCommands: [FileSlashCommand]

    private var unsubscribeAgent: (() -> Void)?
    private var eventListeners: [UUID: (AgentSessionEvent) -> Void] = [:]

    private var steeringMessages: [String] = []
    private var followUpMessages: [String] = []

    private var compactionAbort: CancellationToken?
    private var branchSummaryAbort: CancellationToken?
    private var bashAbort: CancellationToken?
    private var pendingBashMessages: [BashExecutionMessage] = []
    private var isCompactingInternal = false
    private var turnIndex = 0

    public init(config: AgentSessionConfig) {
        self.agent = config.agent
        self.sessionManager = config.sessionManager
        self.settingsManager = config.settingsManager
        self.modelRegistry = config.modelRegistry
        self._hookRunner = config.hookRunner
        self.customToolsInternal = config.customTools ?? []
        self.scopedModels = config.scopedModels ?? []
        self.fileCommands = config.fileCommands ?? []

        self._hookRunner?.initialize(getModel: { [weak agent] in
            agent?.state.model
        }, hasUI: false)

        self.unsubscribeAgent = agent.subscribe { [weak self] event in
            self?.handleAgentEvent(event)
        }
    }

    public func dispose() {
        unsubscribeAgent?()
        unsubscribeAgent = nil
    }

    public var hookRunner: HookRunner? {
        _hookRunner
    }

    public var customTools: [LoadedCustomTool] {
        customToolsInternal
    }

    public func emitCustomToolSessionEvent(
        _ reason: CustomToolSessionEvent.Reason,
        previousSessionFile: String? = nil
    ) async {
        guard !customToolsInternal.isEmpty else { return }

        let event = CustomToolSessionEvent(reason: reason, previousSessionFile: previousSessionFile)
        let context = CustomToolContext(
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: agent.state.model,
            isIdle: { [weak self] in
                !(self?.isStreaming ?? true)
            },
            hasPendingMessages: { [weak self] in
                (self?.pendingMessageCount ?? 0) > 0
            },
            abort: { [weak self] in
                Task { await self?.abort() }
            }
        )

        for tool in customToolsInternal {
            guard let handler = tool.tool.onSession else { continue }
            do {
                try await handler(event, context)
            } catch {
                // Ignore tool errors during session events
            }
        }
    }

    public func subscribe(_ listener: @escaping (AgentSessionEvent) -> Void) -> () -> Void {
        let id = UUID()
        eventListeners[id] = listener
        return { [weak self] in
            self?.eventListeners[id] = nil
        }
    }

    private func emit(_ event: AgentSessionEvent) {
        for listener in eventListeners.values {
            listener(event)
        }
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        if case .messageStart(let message) = event, message.role == "user" {
            let text = extractUserMessageText(message)
            if let idx = steeringMessages.firstIndex(of: text) {
                steeringMessages.remove(at: idx)
            } else if let idx = followUpMessages.firstIndex(of: text) {
                followUpMessages.remove(at: idx)
            }
        }

        if case .messageEnd(let message) = event {
            switch message {
            case .user, .assistant, .toolResult:
                _ = sessionManager.appendMessage(message)
            case .custom(let custom):
                if custom.role == "hookMessage" {
                    if let payload = custom.payload?.value as? [String: Any],
                       let customType = payload["customType"] as? String,
                       let display = payload["display"] as? Bool {
                        let content: HookMessageContent
                        if let text = payload["content"] as? String {
                            content = .text(text)
                        } else {
                            content = .text("")
                        }
                        _ = sessionManager.appendCustomMessage(customType, content, display)
                    }
                } else {
                    _ = sessionManager.appendMessage(message)
                }
            }
        }

        if case .agentEnd = event {
            flushPendingBashMessages()
        }

        if let hookRunner = _hookRunner {
            switch event {
            case .agentStart:
                turnIndex = 0
                Task { _ = await hookRunner.emit(AgentStartEvent()) }
            case .agentEnd(let messages):
                Task { _ = await hookRunner.emit(AgentEndEvent(messages: messages)) }
            case .turnStart:
                let currentIndex = turnIndex
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                Task { _ = await hookRunner.emit(TurnStartEvent(turnIndex: currentIndex, timestamp: timestamp)) }
            case .turnEnd(let message, let toolResults):
                let currentIndex = turnIndex
                turnIndex += 1
                Task { _ = await hookRunner.emit(TurnEndEvent(turnIndex: currentIndex, message: message, toolResults: toolResults)) }
            default:
                break
            }
        }

        emit(.agent(event))
    }

    public var isStreaming: Bool {
        agent.state.isStreaming
    }

    public var messages: [AgentMessage] {
        agent.state.messages
    }

    public var sessionFile: String? {
        sessionManager.getSessionFile()
    }

    public var sessionId: String {
        sessionManager.getSessionId()
    }

    public var pendingMessageCount: Int {
        steeringMessages.count + followUpMessages.count
    }

    public func prompt(_ text: String, options: PromptOptions? = nil) async throws {
        if isStreaming {
            throw NSError(domain: "AgentSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent is already processing. Use steer() or followUp() to queue messages during streaming."])
        }

        if agent.state.model.id.isEmpty {
            throw NSError(domain: "AgentSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "No model selected"])
        }

        let expandedText: String
        if options?.expandSlashCommands ?? true {
            expandedText = expandSlashCommand(text, fileCommands)
        } else {
            expandedText = text
        }
        var messages: [AgentMessage] = [buildUserMessage(text: expandedText, images: options?.images)]
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("before_agent_start") {
            if let result = await hookRunner.emitBeforeAgentStart(expandedText, options?.images),
               let message = result.message {
                let hookMessage = HookMessage(
                    customType: message.customType,
                    content: message.content,
                    display: message.display,
                    details: message.details,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                )
                messages.append(makeHookAgentMessage(hookMessage))
            }
        }
        try await agent.prompt(messages)
    }

    public func `continue`() async throws {
        if isStreaming {
            throw NSError(domain: "AgentSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "Agent is already processing. Wait for completion before continuing."])
        }
        try await agent.continue()
    }

    public func steer(_ text: String) {
        steeringMessages.append(text)
        agent.steer(buildUserMessage(text: text, images: nil))
    }

    public func followUp(_ text: String) {
        followUpMessages.append(text)
        agent.followUp(buildUserMessage(text: text, images: nil))
    }

    public func sendHookMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) async {
        let hookMessage = HookMessage(
            customType: message.customType,
            content: message.content,
            display: message.display,
            details: message.details
        )
        let agentMessage = makeHookAgentMessage(hookMessage)

        if isStreaming {
            if options?.deliverAs == .followUp {
                agent.followUp(agentMessage)
            } else {
                agent.steer(agentMessage)
            }
            return
        }

        if options?.triggerTurn == true {
            do {
                try await agent.prompt(agentMessage)
            } catch {
                return
            }
            return
        }

        agent.appendMessage(agentMessage)
        _ = sessionManager.appendCustomMessage(
            message.customType,
            message.content,
            message.display,
            details: message.details
        )
    }

    public func clearQueue() -> (steering: [String], followUp: [String]) {
        let steering = steeringMessages
        let follow = followUpMessages
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        return (steering, follow)
    }

    public func abort() async {
        agent.abort()
        compactionAbort?.cancel()
        branchSummaryAbort?.cancel()
        bashAbort?.cancel()
    }

    public var isBashRunning: Bool {
        bashAbort != nil
    }

    public func executeBash(_ command: String, onChunk: (@Sendable (String) -> Void)? = nil) async throws -> BashResult {
        let abortToken = CancellationToken()
        bashAbort = abortToken
        defer { bashAbort = nil }

        let result = try await PiSwiftCodingAgent.executeBash(command, options: BashExecutorOptions(onChunk: onChunk, signal: abortToken))
        let message = BashExecutionMessage(
            command: command,
            output: result.output,
            exitCode: result.exitCode,
            cancelled: result.cancelled,
            truncated: result.truncated,
            fullOutputPath: result.fullOutputPath
        )

        if isStreaming {
            pendingBashMessages.append(message)
        } else {
            let agentMessage = makeBashExecutionAgentMessage(message)
            agent.appendMessage(agentMessage)
            _ = sessionManager.appendMessage(agentMessage)
        }

        return result
    }

    public func abortBash() {
        bashAbort?.cancel()
    }

    private func flushPendingBashMessages() {
        guard !pendingBashMessages.isEmpty else { return }
        for message in pendingBashMessages {
            let agentMessage = makeBashExecutionAgentMessage(message)
            agent.appendMessage(agentMessage)
            _ = sessionManager.appendMessage(agentMessage)
        }
        pendingBashMessages.removeAll()
    }

    public var autoCompactionEnabled: Bool {
        settingsManager.getCompactionEnabled()
    }

    public var isCompacting: Bool {
        isCompactingInternal
    }

    public var steeringMode: String {
        agent.getSteeringMode().rawValue
    }

    public var followUpMode: String {
        agent.getFollowUpMode().rawValue
    }

    public func setAutoCompactionEnabled(_ enabled: Bool) {
        settingsManager.setCompactionEnabled(enabled)
    }

    public func setAutoRetryEnabled(_ enabled: Bool) {
        settingsManager.setRetryEnabled(enabled)
    }

    public func abortRetry() {
        // Auto-retry is not implemented in the Swift port yet.
    }

    public func newSession(_ options: NewSessionOptions? = nil) async -> Bool {
        let previousSession = sessionFile
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_switch") {
            if let result = await hookRunner.emit(SessionBeforeSwitchEvent(reason: .new)) as? SessionBeforeSwitchResult,
               result.cancel {
                return false
            }
        }
        await abort()
        agent.reset()
        _ = sessionManager.newSession(options)
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionSwitchEvent(reason: .new, previousSessionFile: previousSession))
        }
        await emitCustomToolSessionEvent(.switch, previousSessionFile: previousSession)
        return true
    }

    public func switchSession(_ sessionPath: String) async -> Bool {
        let previousSession = sessionFile
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_switch") {
            if let result = await hookRunner.emit(SessionBeforeSwitchEvent(reason: .resume, targetSessionFile: sessionPath)) as? SessionBeforeSwitchResult,
               result.cancel {
                return false
            }
        }
        await abort()
        agent.reset()
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        sessionManager.setSessionFile(sessionPath)
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionSwitchEvent(reason: .resume, previousSessionFile: previousSession))
        }
        syncAgentContext()
        await emitCustomToolSessionEvent(.switch, previousSessionFile: previousSession)
        return true
    }

    public func getAvailableModels() async -> [Model] {
        await modelRegistry.getAvailable()
    }

    public func setModel(_ model: Model) async throws {
        guard await modelRegistry.getApiKey(model.provider) != nil else {
            throw NSError(domain: "AgentSession", code: 10, userInfo: [NSLocalizedDescriptionKey: "No API key for \(model.provider)/\(model.id)"])
        }
        agent.setModel(model)
        sessionManager.appendModelChange(model.provider, model.id)
        settingsManager.setDefaultModelAndProvider(model.provider, model.id)
        setThinkingLevel(agent.state.thinkingLevel)
    }

    public func cycleModel(direction: ModelCycleDirection = .forward) async throws -> ModelCycleResult? {
        if !scopedModels.isEmpty {
            return try await cycleScopedModel(direction)
        }
        return try await cycleAvailableModel(direction)
    }

    private func cycleScopedModel(_ direction: ModelCycleDirection) async throws -> ModelCycleResult? {
        guard scopedModels.count > 1 else { return nil }
        let current = agent.state.model
        let currentIndex = scopedModels.firstIndex { modelsAreEqual($0.model, current) } ?? 0
        let count = scopedModels.count
        let nextIndex = direction == .forward ? (currentIndex + 1) % count : (currentIndex - 1 + count) % count
        let next = scopedModels[nextIndex]
        guard await modelRegistry.getApiKey(next.model.provider) != nil else {
            throw NSError(domain: "AgentSession", code: 11, userInfo: [NSLocalizedDescriptionKey: "No API key for \(next.model.provider)/\(next.model.id)"])
        }
        agent.setModel(next.model)
        sessionManager.appendModelChange(next.model.provider, next.model.id)
        settingsManager.setDefaultModelAndProvider(next.model.provider, next.model.id)
        setThinkingLevel(next.thinkingLevel)
        return ModelCycleResult(model: next.model, thinkingLevel: agent.state.thinkingLevel, isScoped: true)
    }

    private func cycleAvailableModel(_ direction: ModelCycleDirection) async throws -> ModelCycleResult? {
        let models = await modelRegistry.getAvailable()
        guard models.count > 1 else { return nil }
        let current = agent.state.model
        let currentIndex = models.firstIndex { modelsAreEqual($0, current) } ?? 0
        let count = models.count
        let nextIndex = direction == .forward ? (currentIndex + 1) % count : (currentIndex - 1 + count) % count
        let next = models[nextIndex]
        guard await modelRegistry.getApiKey(next.provider) != nil else {
            throw NSError(domain: "AgentSession", code: 12, userInfo: [NSLocalizedDescriptionKey: "No API key for \(next.provider)/\(next.id)"])
        }
        agent.setModel(next)
        sessionManager.appendModelChange(next.provider, next.id)
        settingsManager.setDefaultModelAndProvider(next.provider, next.id)
        setThinkingLevel(agent.state.thinkingLevel)
        return ModelCycleResult(model: next, thinkingLevel: agent.state.thinkingLevel, isScoped: false)
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        var effective = level
        if !agent.state.model.reasoning {
            effective = .off
        } else if level == .xhigh && !supportsXhigh(model: agent.state.model) {
            effective = .high
        }
        agent.setThinkingLevel(effective)
        sessionManager.appendThinkingLevelChange(effective.rawValue)
        settingsManager.setDefaultThinkingLevel(effective.rawValue)
    }

    public func cycleThinkingLevel() -> ThinkingLevel? {
        guard agent.state.model.reasoning else { return nil }
        let levels: [ThinkingLevel] = supportsXhigh(model: agent.state.model)
            ? [.off, .minimal, .low, .medium, .high, .xhigh]
            : [.off, .minimal, .low, .medium, .high]
        let currentIndex = levels.firstIndex(of: agent.state.thinkingLevel) ?? 0
        let next = levels[(currentIndex + 1) % levels.count]
        setThinkingLevel(next)
        return next
    }

    public func setSteeringMode(_ mode: AgentSteeringMode) {
        agent.setSteeringMode(mode)
        settingsManager.setSteeringMode(mode.rawValue)
    }

    public func setFollowUpMode(_ mode: AgentFollowUpMode) {
        agent.setFollowUpMode(mode)
        settingsManager.setFollowUpMode(mode.rawValue)
    }

    public func getSessionStats() -> SessionStats {
        let state = agent.state
        let userMessages = state.messages.filter { $0.role == "user" }.count
        let assistantMessages = state.messages.filter { $0.role == "assistant" }.count
        let toolResults = state.messages.filter { $0.role == "toolResult" }.count

        var toolCalls = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0

        for message in state.messages {
            if case .assistant(let assistant) = message {
                toolCalls += assistant.content.filter {
                    if case .toolCall = $0 { return true }
                    return false
                }.count
                totalInput += assistant.usage.input
                totalOutput += assistant.usage.output
                totalCacheRead += assistant.usage.cacheRead
                totalCacheWrite += assistant.usage.cacheWrite
                totalCost += assistant.usage.cost.total
            }
        }

        let tokens = SessionStats.TokenStats(
            input: totalInput,
            output: totalOutput,
            cacheRead: totalCacheRead,
            cacheWrite: totalCacheWrite,
            total: totalInput + totalOutput + totalCacheRead + totalCacheWrite
        )
        return SessionStats(
            sessionFile: sessionFile,
            sessionId: sessionId,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            toolCalls: toolCalls,
            toolResults: toolResults,
            totalMessages: state.messages.count,
            tokens: tokens,
            cost: totalCost
        )
    }

    public func getLastAssistantText() -> String? {
        let lastAssistant = agent.state.messages.reversed().first { message in
            if case .assistant(let assistant) = message {
                return !(assistant.stopReason == .aborted && assistant.content.isEmpty)
            }
            return false
        }
        guard case .assistant(let assistant)? = lastAssistant else { return nil }
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let text) = block {
                return text.text
            }
            return nil
        }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    public func getUserMessagesForBranching() -> [BranchableMessage] {
        let entries = sessionManager.getEntries()
        var result: [BranchableMessage] = []
        for entry in entries {
            if case .message(let msg) = entry, case .user(let user) = msg.message {
                let text = extractUserContentText(user.content)
                result.append(BranchableMessage(entryId: entry.id, text: text))
            }
        }
        return result
    }

    public func branch(_ entryId: String) async throws -> (selectedText: String, cancelled: Bool) {
        let selectedEntry = sessionManager.getEntry(entryId)
        guard case .message(let msg) = selectedEntry, case .user(let user) = msg.message else {
            throw NSError(domain: "AgentSession", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid entry ID for branching"])
        }

        let selectedText = extractUserContentText(user.content)
        let previousSession = sessionFile
        var skipConversationRestore = false

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_branch") {
            if let result = await hookRunner.emit(SessionBeforeBranchEvent(entryId: entryId)) as? SessionBeforeBranchResult {
                if result.cancel {
                    return (selectedText, true)
                }
                skipConversationRestore = result.skipConversationRestore
            }
        }

        if msg.parentId == nil {
            _ = sessionManager.newSession()
        } else if let parentId = msg.parentId {
            _ = sessionManager.createBranchedSession(parentId)
        }

        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionBranchEvent(previousSessionFile: previousSession))
        }

        await emitCustomToolSessionEvent(.branch, previousSessionFile: previousSession)

        if !skipConversationRestore {
            syncAgentContext()
        }

        return (selectedText, false)
    }

    public func navigateTree(
        _ targetId: String,
        summarize: Bool = false,
        customInstructions: String? = nil
    ) async -> (editorText: String?, cancelled: Bool, aborted: Bool?, summaryEntry: BranchSummaryEntry?) {
        let oldLeafId = sessionManager.getLeafId()
        if targetId == oldLeafId {
            return (nil, false, nil, nil)
        }

        guard let targetEntry = sessionManager.getEntry(targetId) else {
            return (nil, true, nil, nil)
        }

        let collection = collectEntriesForBranchSummary(sessionManager, oldLeafId, targetId)
        let preparation = TreePreparation(
            targetId: targetId,
            oldLeafId: oldLeafId,
            commonAncestorId: collection.commonAncestorId,
            entriesToSummarize: collection.entries,
            userWantsSummary: summarize
        )

        branchSummaryAbort = CancellationToken()
        var summaryText: String?
        var summaryDetails: AnyCodable?
        var fromHook = false

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_tree") {
            if let result = await hookRunner.emit(SessionBeforeTreeEvent(preparation: preparation, signal: branchSummaryAbort)) as? SessionBeforeTreeResult {
                if result.cancel {
                    return (nil, true, nil, nil)
                }
                if let summary = result.summary {
                    summaryText = summary.summary
                    summaryDetails = AnyCodable([
                        "readFiles": summary.readFiles ?? [],
                        "modifiedFiles": summary.modifiedFiles ?? [],
                    ])
                    fromHook = true
                }
            }
        }

        if summarize && summaryText == nil && !collection.entries.isEmpty {
            guard let model = agent.state.model as Model? else {
                return (nil, true, nil, nil)
            }
            if let apiKey = await modelRegistry.getApiKey(model.provider) {
                let options = GenerateBranchSummaryOptions(
                    model: model,
                    apiKey: apiKey,
                    signal: branchSummaryAbort,
                    customInstructions: customInstructions,
                    reserveTokens: settingsManager.getBranchSummarySettings().reserveTokens
                )
                let result = await generateBranchSummary(collection.entries, options)
                if result.aborted == true {
                    return (nil, true, true, nil)
                }
                if result.error != nil {
                    return (nil, true, nil, nil)
                }
                summaryText = result.summary
                let details = BranchSummaryDetails(readFiles: result.readFiles ?? [], modifiedFiles: result.modifiedFiles ?? [])
                summaryDetails = AnyCodable(["readFiles": details.readFiles, "modifiedFiles": details.modifiedFiles])
            }
        }

        let newLeafId: String?
        var editorText: String?

        switch targetEntry {
        case .message(let msg):
            if case .user(let user) = msg.message {
                newLeafId = msg.parentId
                editorText = extractUserContentText(user.content)
            } else {
                newLeafId = targetId
            }
        case .customMessage(let custom):
            newLeafId = custom.parentId
            switch custom.content {
            case .text(let text):
                editorText = text
            case .blocks(let blocks):
                editorText = blocks.compactMap { block in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined()
            }
        default:
            newLeafId = targetId
        }

        var summaryEntry: BranchSummaryEntry?
        if let summaryText {
            let summaryId = sessionManager.branchWithSummary(newLeafId, summaryText, details: summaryDetails, fromHook: fromHook)
            if case .branchSummary(let entry) = sessionManager.getEntry(summaryId) {
                summaryEntry = entry
            }
        } else if newLeafId == nil {
            sessionManager.resetLeaf()
        } else if let newLeafId {
            sessionManager.branch(newLeafId)
        }

        syncAgentContext()

        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionTreeEvent(newLeafId: sessionManager.getLeafId(), oldLeafId: oldLeafId, summaryEntry: summaryEntry, fromHook: summaryEntry != nil ? fromHook : nil))
        }

        await emitCustomToolSessionEvent(.tree, previousSessionFile: sessionFile)

        return (editorText, false, nil, summaryEntry)
    }

    public func abortCompaction() {
        compactionAbort?.cancel()
    }

    public func abortBranchSummary() {
        branchSummaryAbort?.cancel()
    }

    public func compact(customInstructions: String? = nil) async throws -> CompactionResult {
        isCompactingInternal = true
        defer { isCompactingInternal = false }
        compactionAbort = CancellationToken()
        defer { compactionAbort = nil }

        let model = agent.state.model
        let apiKey = await modelRegistry.getApiKey(model.provider)
        if apiKey == nil {
            throw NSError(domain: "AgentSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "No API key for \(model.provider)"])
        }

        let pathEntries = sessionManager.getBranch()
        let settings = settingsManager.getCompactionSettings()
        guard let preparation = prepareCompaction(pathEntries, settings) else {
            throw NSError(domain: "AgentSession", code: 6, userInfo: [NSLocalizedDescriptionKey: "Nothing to compact (session too small)"])
        }

        var hookCompaction: CompactionResult?
        var fromHook = false
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_compact") {
            if let result = await hookRunner.emit(SessionBeforeCompactEvent(preparation: preparation, branchEntries: pathEntries, customInstructions: customInstructions, signal: compactionAbort)) as? SessionBeforeCompactResult {
                if result.cancel {
                    throw NSError(domain: "AgentSession", code: 7, userInfo: [NSLocalizedDescriptionKey: "Compaction cancelled"])
                }
                if let compaction = result.compaction {
                    hookCompaction = compaction
                    fromHook = true
                }
            }
        }

        let result: CompactionResult
        if let hookCompaction {
            result = hookCompaction
        } else if let apiKey {
            result = try await PiSwiftCodingAgent.compact(
                preparation,
                model,
                apiKey,
                customInstructions: customInstructions,
                signal: compactionAbort
            )
        } else {
            throw NSError(domain: "AgentSession", code: 8, userInfo: [NSLocalizedDescriptionKey: "No API key for \(model.provider)"])
        }

        if compactionAbort?.isCancelled == true {
            throw NSError(domain: "AgentSession", code: 9, userInfo: [NSLocalizedDescriptionKey: "Compaction cancelled"])
        }

        _ = sessionManager.appendCompaction(
            result.summary,
            result.firstKeptEntryId,
            result.tokensBefore,
            details: result.details,
            fromHook: fromHook
        )

        syncAgentContext()

        if let hookRunner = _hookRunner {
            if let entry = sessionManager.getEntries().compactMap({ entry -> CompactionEntry? in
                if case .compaction(let compaction) = entry { return compaction }
                return nil
            }).last {
                _ = await hookRunner.emit(SessionCompactEvent(compactionEntry: entry, fromHook: fromHook))
            }
        }

        return result
    }

    private func syncAgentContext() {
        let context = sessionManager.buildSessionContext()
        agent.replaceMessages(context.messages)
        if let modelInfo = context.model {
            if let model = modelRegistry.find(modelInfo.provider, modelInfo.modelId) {
                agent.setModel(model)
            }
        }
        agent.setThinkingLevel(ThinkingLevel(rawValue: context.thinkingLevel) ?? .off)
    }

    private func buildUserMessage(text: String, images: [ImageContent]?) -> AgentMessage {
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        if let images {
            blocks.append(contentsOf: images.map { .image($0) })
        }
        return AgentMessage.user(UserMessage(content: .blocks(blocks)))
    }

    private func extractUserMessageText(_ message: AgentMessage) -> String {
        switch message {
        case .user(let user):
            return extractUserContentText(user.content)
        default:
            return ""
        }
    }

    private func extractUserContentText(_ content: UserContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined()
        }
    }
}
