import Foundation
import PiSwiftAI

private func defaultConvertToLlm(messages: [AgentMessage]) async -> [Message] {
    messages.compactMap { $0.asMessage }
}

public struct AgentOptions: @unchecked Sendable {
    public var initialState: AgentState?
    public var convertToLlm: (([AgentMessage]) async throws -> [Message])?
    public var transformContext: (([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?
    public var steeringMode: AgentSteeringMode?
    public var followUpMode: AgentFollowUpMode?
    public var streamFn: StreamFn?
    public var getApiKey: ((String) async -> String?)?

    public init(
        initialState: AgentState? = nil,
        convertToLlm: (([AgentMessage]) async throws -> [Message])? = nil,
        transformContext: (([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = nil,
        steeringMode: AgentSteeringMode? = nil,
        followUpMode: AgentFollowUpMode? = nil,
        streamFn: StreamFn? = nil,
        getApiKey: ((String) async -> String?)? = nil
    ) {
        self.initialState = initialState
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.streamFn = streamFn
        self.getApiKey = getApiKey
    }
}

public final class Agent: @unchecked Sendable {
    private var _state: AgentState
    private var listeners: [UUID: (AgentEvent) -> Void] = [:]
    private var abortToken: CancellationToken?
    private var convertToLlm: ([AgentMessage]) async throws -> [Message]
    private var transformContext: (([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?
    private var steeringQueue: [AgentMessage] = []
    private var followUpQueue: [AgentMessage] = []
    private var steeringMode: AgentSteeringMode
    private var followUpMode: AgentFollowUpMode
    public var streamFn: StreamFn
    public var getApiKey: ((String) async -> String?)?
    private var runningTask: Task<Void, Never>?

    public init(_ options: AgentOptions = AgentOptions()) {
        self._state = options.initialState ?? AgentState()
        self.convertToLlm = options.convertToLlm ?? { messages in
            await defaultConvertToLlm(messages: messages)
        }
        self.transformContext = options.transformContext
        self.steeringMode = options.steeringMode ?? .oneAtATime
        self.followUpMode = options.followUpMode ?? .oneAtATime
        self.streamFn = options.streamFn ?? { model, context, options in
            try streamSimple(model: model, context: context, options: options)
        }
        self.getApiKey = options.getApiKey
    }

    public var state: AgentState {
        _state
    }

    public func subscribe(_ fn: @escaping (AgentEvent) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in
            self?.listeners[id] = nil
        }
    }

    public func setSystemPrompt(_ value: String) {
        _state.systemPrompt = value
    }

    public func setModel(_ model: Model) {
        _state.model = model
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        _state.thinkingLevel = level
    }

    public func setSteeringMode(_ mode: AgentSteeringMode) {
        steeringMode = mode
    }

    public func setFollowUpMode(_ mode: AgentFollowUpMode) {
        followUpMode = mode
    }

    public func getSteeringMode() -> AgentSteeringMode {
        steeringMode
    }

    public func getFollowUpMode() -> AgentFollowUpMode {
        followUpMode
    }

    public func setTools(_ tools: [AgentTool]) {
        _state.tools = tools
    }

    public func replaceMessages(_ messages: [AgentMessage]) {
        _state.messages = messages
    }

    public func appendMessage(_ message: AgentMessage) {
        _state.messages.append(message)
    }

    public func steer(_ message: AgentMessage) {
        steeringQueue.append(message)
    }

    public func followUp(_ message: AgentMessage) {
        followUpQueue.append(message)
    }

    public func clearMessageQueue() {
        clearAllQueues()
    }

    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    public func clearFollowUpQueue() {
        followUpQueue.removeAll()
    }

    public func clearAllQueues() {
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    public func clearMessages() {
        _state.messages.removeAll()
    }

    public func abort() {
        abortToken?.cancel()
    }

    public func waitForIdle() async {
        if let task = runningTask {
            await task.value
        }
    }

    public func reset() {
        _state.messages.removeAll()
        _state.isStreaming = false
        _state.streamMessage = nil
        _state.pendingToolCalls = Set<String>()
        _state.error = nil
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    public func prompt(_ message: AgentMessage) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        await runLoop(messages: [message])
    }

    public func prompt(_ messages: [AgentMessage]) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        await runLoop(messages: messages)
    }

    public func prompt(_ text: String, images: [ImageContent] = []) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        if !images.isEmpty {
            blocks.append(contentsOf: images.map { .image($0) })
        }
        let message = AgentMessage.user(UserMessage(content: .blocks(blocks)))
        await runLoop(messages: [message])
    }

    public func `continue`() async throws {
        try ensureNotStreaming(.alreadyStreamingContinue)
        guard !_state.messages.isEmpty else { throw AgentError.emptyContext }
        if let last = _state.messages.last, last.role == "assistant" { throw AgentError.lastMessageAssistant }

        await runLoop(messages: nil)
    }

    private func runLoop(messages: [AgentMessage]?) async {
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoopInternal(messages: messages)
        }
        if let task = runningTask {
            await task.value
        }
        runningTask = nil
    }

    private func runLoopInternal(messages: [AgentMessage]?) async {
        let model = _state.model

        abortToken = CancellationToken()
        _state.isStreaming = true
        _state.streamMessage = nil
        _state.error = nil

        let reasoning = mapThinkingLevel(_state.thinkingLevel)

        let context = AgentContext(
            systemPrompt: _state.systemPrompt,
            messages: _state.messages,
            tools: _state.tools
        )

        let config = AgentLoopConfig(
            model: model,
            reasoning: reasoning,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            getApiKey: getApiKey,
            getSteeringMessages: { [weak self] in
                guard let self else { return [] }
                switch self.steeringMode {
                case .oneAtATime:
                    if let first = self.steeringQueue.first {
                        self.steeringQueue.removeFirst()
                        return [first]
                    }
                    return []
                case .all:
                    let queued = self.steeringQueue
                    self.steeringQueue.removeAll()
                    return queued
                }
            },
            getFollowUpMessages: { [weak self] in
                guard let self else { return [] }
                switch self.followUpMode {
                case .oneAtATime:
                    if let first = self.followUpQueue.first {
                        self.followUpQueue.removeFirst()
                        return [first]
                    }
                    return []
                case .all:
                    let queued = self.followUpQueue
                    self.followUpQueue.removeAll()
                    return queued
                }
            }
        )

        var partial: AgentMessage? = nil

        do {
            let stream: EventStream<AgentEvent, [AgentMessage]>
            if let messages {
                stream = agentLoop(
                    prompts: messages,
                    context: context,
                    config: config,
                    signal: abortToken,
                    streamFn: streamFn
                )
            } else {
                stream = try agentLoopContinue(
                    context: context,
                    config: config,
                    signal: abortToken,
                    streamFn: streamFn
                )
            }

            for await event in stream {
                switch event {
                case .messageStart(let message):
                    partial = message
                    _state.streamMessage = message

                case .messageUpdate(let message, _):
                    partial = message
                    _state.streamMessage = message

                case .messageEnd(let message):
                    partial = nil
                    _state.streamMessage = nil
                    appendMessage(message)

                case .toolExecutionStart(let toolCallId, _, _):
                    var pending = _state.pendingToolCalls
                    pending.insert(toolCallId)
                    _state.pendingToolCalls = pending

                case .toolExecutionEnd(let toolCallId, _, _, _):
                    var pending = _state.pendingToolCalls
                    pending.remove(toolCallId)
                    _state.pendingToolCalls = pending

                case .turnEnd(let message, _):
                    if case .assistant(let assistantMessage) = message, let error = assistantMessage.errorMessage {
                        _state.error = error
                    }

                case .agentEnd:
                    _state.isStreaming = false
                    _state.streamMessage = nil

                default:
                    break
                }

                emit(event)
            }

            if let partial = partial, case .assistant(let assistantMessage) = partial {
                let hasContent = assistantMessage.content.contains { block in
                    switch block {
                    case .thinking(let thinking):
                        return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .text(let text):
                        return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .toolCall(let call):
                        return !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .image:
                        return true
                    }
                }

                if hasContent {
                    appendMessage(partial)
                } else if abortToken?.isCancelled == true {
                    appendErrorMessage("Request was aborted")
                }
            }
        } catch {
            let errorMessage = error.localizedDescription
            appendErrorMessage(errorMessage)
            emit(.agentEnd(messages: _state.messages))
        }

        _state.isStreaming = false
        _state.streamMessage = nil
        _state.pendingToolCalls = Set<String>()
        abortToken = nil
    }

    private func emit(_ event: AgentEvent) {
        for listener in listeners.values {
            listener(event)
        }
    }

    private func appendErrorMessage(_ message: String) {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            api: _state.model.api,
            provider: _state.model.provider,
            model: _state.model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: abortToken?.isCancelled == true ? .aborted : .error,
            errorMessage: message
        )
        let agentMessage = AgentMessage.assistant(assistant)
        appendMessage(agentMessage)
        _state.error = message
    }

    private func mapThinkingLevel(_ level: ThinkingLevel) -> ReasoningEffort? {
        switch level {
        case .off:
            return nil
        case .minimal:
            return .low
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .xhigh:
            return .xhigh
        }
    }

    private func ensureNotStreaming(_ error: AgentError) throws {
        if _state.isStreaming {
            throw error
        }
    }
}

public enum AgentError: Error, LocalizedError {
    case emptyContext
    case lastMessageAssistant
    case alreadyStreamingPrompt
    case alreadyStreamingContinue

    public var errorDescription: String? {
        switch self {
        case .emptyContext:
            return "No messages to continue from"
        case .lastMessageAssistant:
            return "Cannot continue from message role: assistant"
        case .alreadyStreamingPrompt:
            return "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
        case .alreadyStreamingContinue:
            return "Agent is already processing. Wait for completion before continuing."
        }
    }
}
