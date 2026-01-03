import Testing
import PiSwiftAI
import PiSwiftAgent

@Test func agentLoopEmitsEvents() async {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let userPrompt = createUserMessage("Hello")

    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Hi there!"))])
        return makeStream(done: message)
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)

    for await event in stream {
        events.append(event)
    }

    let messages = await stream.result()
    #expect(messages.count == 2)
    #expect(messages.first?.role == "user")
    #expect(messages.last?.role == "assistant")

    let eventTypes = events.map { event in
        switch event {
        case .agentStart: return "agent_start"
        case .turnStart: return "turn_start"
        case .messageStart: return "message_start"
        case .messageEnd: return "message_end"
        case .turnEnd: return "turn_end"
        case .agentEnd: return "agent_end"
        case .messageUpdate: return "message_update"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        }
    }

    #expect(eventTypes.contains("agent_start"))
    #expect(eventTypes.contains("turn_start"))
    #expect(eventTypes.contains("message_start"))
    #expect(eventTypes.contains("message_end"))
    #expect(eventTypes.contains("turn_end"))
    #expect(eventTypes.contains("agent_end"))
}

@Test func customMessagesWithConverter() async {
    let notification = AgentMessage.custom(AgentCustomMessage(role: "notification", payload: AnyCodable("note")))

    let context = AgentContext(systemPrompt: "You are helpful.", messages: [notification], tools: [])
    let userPrompt = createUserMessage("Hello")

    var converted: [Message] = []
    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: { messages in
            converted = messages.compactMap { message in
                if case .custom(let custom) = message, custom.role == "notification" {
                    return nil
                }
                return message.asMessage
            }
            return converted
        }
    )

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    #expect(converted.count == 1)
    #expect(converted.first?.role == "user")
}

@Test func transformContextBeforeConvert() async {
    let context = AgentContext(
        systemPrompt: "You are helpful.",
        messages: [
            createUserMessage("old message 1"),
            AgentMessage.assistant(createAssistantMessage(content: [.text(TextContent(text: "old response 1"))])),
            createUserMessage("old message 2"),
            AgentMessage.assistant(createAssistantMessage(content: [.text(TextContent(text: "old response 2"))]))
        ],
        tools: []
    )

    let userPrompt = createUserMessage("new message")

    var transformed: [AgentMessage] = []
    var converted: [Message] = []

    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: { messages in
            converted = messages.compactMap { $0.asMessage }
            return converted
        },
        transformContext: { messages, _ in
            transformed = Array(messages.suffix(2))
            return transformed
        }
    )

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    #expect(transformed.count == 2)
    #expect(converted.count == 2)
}

@Test func toolCallsAndResults() async {
    var executed: [String] = []
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        executed.append(value)
        return AgentToolResult(content: [.text(TextContent(text: "echoed: \(value)"))], details: AnyCodable(["value": value]))
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("echo something")
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    var callIndex = 0
    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        if callIndex == 0 {
            let toolCall = ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable("hello")])
            let message = createAssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
        } else {
            let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        callIndex += 1
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    #expect(executed == ["hello"])

    let toolStart = events.first { if case .toolExecutionStart = $0 { return true } else { return false } }
    let toolEnd = events.first { if case .toolExecutionEnd = $0 { return true } else { return false } }
    #expect(toolStart != nil)
    #expect(toolEnd != nil)

    if case .toolExecutionEnd(_, _, _, let isError) = toolEnd {
        #expect(!isError)
    }
}

@Test func steeringMessagesSkipRemainingTools() async {
    var executed: [String] = []
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        executed.append(value)
        return AgentToolResult(content: [.text(TextContent(text: "ok:\(value)"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let steeringUserMessage = createUserMessage("interrupt")

    var steeringDelivered = false
    var callIndex = 0
    var sawInterruptInContext = false

    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: identityConverter,
        getSteeringMessages: {
            if executed.count == 1 && !steeringDelivered {
                steeringDelivered = true
                return [steeringUserMessage]
            }
            return []
        }
    )

    let streamFn: StreamFn = { _, ctx, _ in
        if callIndex == 1 {
            sawInterruptInContext = ctx.messages.contains { message in
                if case .user(let user) = message, case .text(let text) = user.content {
                    return text == "interrupt"
                }
                return false
            }
        }

        let stream = AssistantMessageEventStream()
        if callIndex == 0 {
            let first = ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable("first")])
            let second = ToolCall(id: "tool-2", name: "echo", arguments: ["value": AnyCodable("second")])
            let message = createAssistantMessage(content: [.toolCall(first), .toolCall(second)], stopReason: .toolUse)
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
        } else {
            let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        callIndex += 1
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    #expect(executed == ["first"])

    let toolEnds = events.compactMap { event -> (AgentToolResult, Bool)? in
        if case .toolExecutionEnd(_, _, let result, let isError) = event {
            return (result, isError)
        }
        return nil
    }
    #expect(toolEnds.count == 2)
    #expect(toolEnds[0].1 == false)
    #expect(toolEnds[1].1 == true)

    if case .text(let text) = toolEnds[1].0.content.first {
        #expect(text.text.contains("Skipped due to queued user message"))
    }

    let steeringEvent = events.first { event in
        if case .messageStart(let message) = event {
            if case .user(let user) = message, case .text(let text) = user.content {
                return text == "interrupt"
            }
        }
        return false
    }
    #expect(steeringEvent != nil)
    #expect(sawInterruptInContext)
}

@Test func agentLoopContinueValidations() {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    do {
        _ = try agentLoopContinue(context: context, config: config)
        #expect(Bool(false), "Expected error for empty context")
    } catch {
        #expect(error.localizedDescription == "Cannot continue: no messages in context")
    }

    let assistant = createAssistantMessage(content: [.text(TextContent(text: "Hi"))])
    let contextWithAssistant = AgentContext(systemPrompt: "You are helpful.", messages: [.assistant(assistant)], tools: [])
    do {
        _ = try agentLoopContinue(context: contextWithAssistant, config: config)
        #expect(Bool(false), "Expected error for assistant last message")
    } catch {
        #expect(error.localizedDescription == "Cannot continue from message role: assistant")
    }
}

@Test func agentLoopContinueWithExistingContext() async throws {
    let userMessage = createUserMessage("Hello")
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [userMessage], tools: [])
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    var events: [AgentEvent] = []
    let stream = try agentLoopContinue(context: context, config: config, streamFn: streamFn)

    for await event in stream {
        events.append(event)
    }

    let messages = await stream.result()
    #expect(messages.count == 1)
    #expect(messages.first?.role == "assistant")

    let messageEnds = events.filter { event in
        if case .messageEnd = event { return true }
        return false
    }
    #expect(messageEnds.count == 1)
}

private func createUsage() -> Usage {
    Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
}

private func createModel() -> Model {
    Model(
        id: "mock",
        name: "mock",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://example.invalid",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192,
        maxTokens: 2048
    )
}

private func createAssistantMessage(content: [ContentBlock], stopReason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAIResponses,
        provider: "openai",
        model: "mock",
        usage: createUsage(),
        stopReason: stopReason
    )
}

private func createUserMessage(_ text: String) -> AgentMessage {
    AgentMessage.user(UserMessage(content: .text(text)))
}

private func identityConverter(messages: [AgentMessage]) async -> [Message] {
    messages.compactMap { $0.asMessage }
}

private func makeStream(done message: AssistantMessage, reason: StopReason = .stop) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    Task {
        stream.push(.done(reason: reason, message: message))
        stream.end(message)
    }
    return stream
}
