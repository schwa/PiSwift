import Testing
import PiSwiftAI
import PiSwiftAgent

@Test func defaultState() {
    let agent = Agent()

    #expect(agent.state.systemPrompt == "")
    #expect(agent.state.thinkingLevel == .off)
    #expect(agent.state.tools.isEmpty)
    #expect(agent.state.messages.isEmpty)
    #expect(!agent.state.isStreaming)
    #expect(agent.state.streamMessage == nil)
    #expect(agent.state.pendingToolCalls.isEmpty)
    #expect(agent.state.error == nil)
}

@Test func customInitialState() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let customState = AgentState(systemPrompt: "You are a helpful assistant.", model: model, thinkingLevel: .low)
    let agent = Agent(AgentOptions(initialState: customState))

    #expect(agent.state.systemPrompt == "You are a helpful assistant.")
    #expect(agent.state.model.id == model.id)
    #expect(agent.state.thinkingLevel == .low)
}

@Test func subscribe() {
    let agent = Agent()
    let eventCount = LockedState(0)
    let unsubscribe = agent.subscribe { _ in
        eventCount.withLock { $0 += 1 }
    }

    #expect(eventCount.withLock { $0 } == 0)
    agent.setSystemPrompt("Test prompt")
    #expect(eventCount.withLock { $0 } == 0)
    #expect(agent.state.systemPrompt == "Test prompt")

    unsubscribe()
    agent.setSystemPrompt("Another prompt")
    #expect(eventCount.withLock { $0 } == 0)
}

@Test func stateMutators() {
    let agent = Agent()
    agent.setSystemPrompt("Custom prompt")
    #expect(agent.state.systemPrompt == "Custom prompt")

    let newModel = getModel(provider: .openai, modelId: "gpt-5-mini")
    agent.setModel(newModel)
    #expect(agent.state.model.id == newModel.id)

    agent.setThinkingLevel(.high)
    #expect(agent.state.thinkingLevel == .high)

    let tool = AgentTool(
        label: "Test",
        name: "test",
        description: "test tool",
        parameters: [:]
    ) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))])
    }
    agent.setTools([tool])
    #expect(agent.state.tools.count == 1)
    #expect(agent.state.tools.first?.name == "test")

    let userMessage = AgentMessage.user(UserMessage(content: .text("Hello")))
    agent.replaceMessages([userMessage])
    #expect(agent.state.messages.count == 1)
    #expect(agent.state.messages.first?.role == "user")

    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "Hi"))],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
    agent.appendMessage(.assistant(assistant))
    #expect(agent.state.messages.count == 2)
    #expect(agent.state.messages.last?.role == "assistant")

    agent.clearMessages()
    #expect(agent.state.messages.isEmpty)
}

@Test func steerAndFollowUp() {
    let agent = Agent()
    let steerMessage = AgentMessage.user(UserMessage(content: .text("Steer message")))
    let followUpMessage = AgentMessage.user(UserMessage(content: .text("Follow-up message")))
    agent.steer(steerMessage)
    agent.followUp(followUpMessage)
    #expect(!agent.state.messages.contains { $0.role == "user" && $0.timestamp == steerMessage.timestamp })
    #expect(!agent.state.messages.contains { $0.role == "user" && $0.timestamp == followUpMessage.timestamp })
}

@Test func promptWhileStreamingThrows() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))
    let task = Task { try await agent.prompt("Hello") }

    var attempts = 0
    while !agent.state.isStreaming && attempts < 50 {
        attempts += 1
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(agent.state.isStreaming)

    do {
        try await agent.prompt("Second")
        #expect(Bool(false), "Expected already streaming error")
    } catch {
        #expect(
            error.localizedDescription ==
                "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
        )
    }

    _ = try await task.value
}

@Test func abort() {
    let agent = Agent()
    agent.abort()
}

@Test func forwardsSessionIdToStreamOptions() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedSessionId = LockedState<String?>(nil)
    let streamFn: StreamFn = { model, _, options in
        receivedSessionId.withLock { $0 = options.sessionId }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn, sessionId: "session-abc"))
    try await agent.prompt("Hello")
    #expect(receivedSessionId.withLock { $0 } == "session-abc")

    agent.sessionId = "session-def"
    try await agent.prompt("Hello again")
    #expect(receivedSessionId.withLock { $0 } == "session-def")
}

@Test func continueWhileStreamingThrows() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))
    let task = Task { try await agent.prompt("Hello") }

    var attempts = 0
    while !agent.state.isStreaming && attempts < 50 {
        attempts += 1
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(agent.state.isStreaming)

    do {
        try await agent.continue()
        #expect(Bool(false), "Expected already streaming error")
    } catch {
        #expect(error.localizedDescription == "Agent is already processing. Wait for completion before continuing.")
    }

    _ = try await task.value
}
