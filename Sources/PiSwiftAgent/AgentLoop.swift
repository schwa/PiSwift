import Foundation
import PiSwiftAI

public func agentLoop(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) -> EventStream<AgentEvent, [AgentMessage]> {
    let stream = createAgentStream()
    let streamFnBox = StreamFnBox(streamFn)

    Task {
        let newMessages = prompts
        let currentContext = AgentContext(
            systemPrompt: context.systemPrompt,
            messages: context.messages + prompts,
            tools: context.tools
        )

        stream.push(.agentStart)
        stream.push(.turnStart)
        for prompt in prompts {
            stream.push(.messageStart(message: prompt))
            stream.push(.messageEnd(message: prompt))
        }

        await runLoop(
            currentContext: currentContext,
            newMessages: newMessages,
            config: config,
            signal: signal,
            stream: stream,
            streamFn: streamFnBox.value
        )
    }

    return stream
}

public func agentLoopContinue(
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) throws -> EventStream<AgentEvent, [AgentMessage]> {
    guard !context.messages.isEmpty else {
        throw AgentLoopError.emptyContext
    }

    if let last = context.messages.last, last.role == "assistant" {
        throw AgentLoopError.lastMessageAssistant
    }

    let stream = createAgentStream()
    let streamFnBox = StreamFnBox(streamFn)

    Task {
        let newMessages: [AgentMessage] = []
        let currentContext = context

        stream.push(.agentStart)
        stream.push(.turnStart)

        await runLoop(
            currentContext: currentContext,
            newMessages: newMessages,
            config: config,
            signal: signal,
            stream: stream,
            streamFn: streamFnBox.value
        )
    }

    return stream
}

private final class StreamFnBox: @unchecked Sendable {
    let value: StreamFn?

    init(_ value: StreamFn?) {
        self.value = value
    }
}

public enum AgentLoopError: Error, LocalizedError {
    case emptyContext
    case lastMessageAssistant

    public var errorDescription: String? {
        switch self {
        case .emptyContext:
            return "Cannot continue: no messages in context"
        case .lastMessageAssistant:
            return "Cannot continue from message role: assistant"
        }
    }
}

private func createAgentStream() -> EventStream<AgentEvent, [AgentMessage]> {
    EventStream<AgentEvent, [AgentMessage]>(
        isComplete: { event in
            if case .agentEnd = event { return true }
            return false
        },
        extractResult: { event in
            if case .agentEnd(let messages) = event { return messages }
            return []
        }
    )
}

private func runLoop(
    currentContext: AgentContext,
    newMessages: [AgentMessage],
    config: AgentLoopConfig,
    signal: CancellationToken?,
    stream: EventStream<AgentEvent, [AgentMessage]>,
    streamFn: StreamFn?
) async {
    var context = currentContext
    var messages = newMessages
    var firstTurn = true
    var pendingMessages = (await config.getSteeringMessages?()) ?? []

    while true {
        var hasMoreToolCalls = true
        var steeringAfterTools: [AgentMessage]? = nil

        while hasMoreToolCalls || !pendingMessages.isEmpty {
            if !firstTurn {
                stream.push(.turnStart)
            } else {
                firstTurn = false
            }

            if !pendingMessages.isEmpty {
                for message in pendingMessages {
                    stream.push(.messageStart(message: message))
                    stream.push(.messageEnd(message: message))
                    context.messages.append(message)
                    messages.append(message)
                }
                pendingMessages.removeAll()
            }

            do {
                let (assistantMessage, updatedContext) = try await streamAssistantResponse(
                    context: context,
                    config: config,
                    signal: signal,
                    stream: stream,
                    streamFn: streamFn
                )
                context = updatedContext
                let agentMessage = AgentMessage.assistant(assistantMessage)
                messages.append(agentMessage)

                if assistantMessage.stopReason == .error || assistantMessage.stopReason == .aborted {
                    stream.push(.turnEnd(message: agentMessage, toolResults: []))
                    stream.push(.agentEnd(messages: messages))
                    stream.end(messages)
                    return
                }

                let toolCalls = assistantMessage.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let toolCall) = block { return toolCall }
                    return nil
                }
                hasMoreToolCalls = !toolCalls.isEmpty

                var toolResults: [ToolResultMessage] = []
                if hasMoreToolCalls {
                    let execution = await executeToolCalls(
                        tools: context.tools,
                        assistantMessage: assistantMessage,
                        signal: signal,
                        stream: stream,
                        getSteeringMessages: config.getSteeringMessages
                    )
                    toolResults.append(contentsOf: execution.toolResults)
                    steeringAfterTools = execution.steeringMessages

                    for result in toolResults {
                        let agentResult = AgentMessage.toolResult(result)
                        context.messages.append(agentResult)
                        messages.append(agentResult)
                    }
                }

                stream.push(.turnEnd(message: agentMessage, toolResults: toolResults))
            } catch {
                let errorMessage = AgentMessage.assistant(buildErrorAssistantMessage(
                    model: config.model,
                    reason: signal?.isCancelled == true ? .aborted : .error,
                    message: error.localizedDescription
                ))
                messages.append(errorMessage)
                stream.push(.turnEnd(message: errorMessage, toolResults: []))
                stream.push(.agentEnd(messages: messages))
                stream.end(messages)
                return
            }

            if let queued = steeringAfterTools, !queued.isEmpty {
                pendingMessages = queued
                steeringAfterTools = nil
            } else {
                pendingMessages = (await config.getSteeringMessages?()) ?? []
            }
        }

        let followUpMessages = (await config.getFollowUpMessages?()) ?? []
        if !followUpMessages.isEmpty {
            pendingMessages = followUpMessages
            continue
        }

        break
    }

    stream.push(.agentEnd(messages: messages))
    stream.end(messages)
}

private func streamAssistantResponse(
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken?,
    stream: EventStream<AgentEvent, [AgentMessage]>,
    streamFn: StreamFn?
) async throws -> (AssistantMessage, AgentContext) {
    var updatedContext = context
    var messages = context.messages

    if let transform = config.transformContext {
        messages = try await transform(messages, signal)
    }

    let llmMessages = try await config.convertToLlm(messages)

    let llmContext = Context(
        systemPrompt: context.systemPrompt,
        messages: llmMessages,
        tools: context.tools?.map { $0.aiTool }
    )

    let streamFunction: StreamFn = streamFn ?? { model, context, options in
        try streamSimple(model: model, context: context, options: options)
    }

    let resolvedApiKey = (await config.getApiKey?(config.model.provider)) ?? config.apiKey

    let response = try await streamFunction(
        config.model,
        llmContext,
        SimpleStreamOptions(
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            signal: signal,
            apiKey: resolvedApiKey,
            reasoning: config.reasoning
        )
    )

    var partialMessage: AssistantMessage? = nil
    var addedPartial = false

    for await event in response {
        switch event {
        case .start(let partial):
            partialMessage = partial
            let agentMessage = AgentMessage.assistant(partial)
            updatedContext.messages.append(agentMessage)
            addedPartial = true
            stream.push(.messageStart(message: agentMessage))

        case .textStart(_, let partial),
             .textDelta(_, _, let partial),
             .textEnd(_, _, let partial),
             .thinkingStart(_, let partial),
             .thinkingDelta(_, _, let partial),
             .thinkingEnd(_, _, let partial),
             .toolCallStart(_, let partial),
             .toolCallDelta(_, _, let partial),
             .toolCallEnd(_, _, let partial):
            if let _ = partialMessage {
                partialMessage = partial
                let agentMessage = AgentMessage.assistant(partial)
                if addedPartial {
                    updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
                } else {
                    updatedContext.messages.append(agentMessage)
                    addedPartial = true
                }
                stream.push(.messageUpdate(message: agentMessage, assistantMessageEvent: event))
            }

        case .done:
            let finalMessage = await response.result()
            let agentMessage = AgentMessage.assistant(finalMessage)
            if addedPartial {
                updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
            } else {
                updatedContext.messages.append(agentMessage)
                stream.push(.messageStart(message: agentMessage))
            }
            stream.push(.messageEnd(message: agentMessage))
            return (finalMessage, updatedContext)

        case .error:
            let finalMessage = await response.result()
            let agentMessage = AgentMessage.assistant(finalMessage)
            if addedPartial {
                updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
            } else {
                updatedContext.messages.append(agentMessage)
                stream.push(.messageStart(message: agentMessage))
            }
            stream.push(.messageEnd(message: agentMessage))
            return (finalMessage, updatedContext)
        }
    }

    let finalMessage = await response.result()
    let agentMessage = AgentMessage.assistant(finalMessage)
    if addedPartial {
        updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
    } else {
        updatedContext.messages.append(agentMessage)
    }
    return (finalMessage, updatedContext)
}

private func executeToolCalls(
    tools: [AgentTool]?,
    assistantMessage: AssistantMessage,
    signal: CancellationToken?,
    stream: EventStream<AgentEvent, [AgentMessage]>,
    getSteeringMessages: (() async -> [AgentMessage])?
) async -> (toolResults: [ToolResultMessage], steeringMessages: [AgentMessage]?) {
    let toolCalls = assistantMessage.content.compactMap { block -> ToolCall? in
        if case .toolCall(let toolCall) = block { return toolCall }
        return nil
    }

    var results: [ToolResultMessage] = []
    var steeringMessages: [AgentMessage]? = nil

    for (index, toolCall) in toolCalls.enumerated() {
        let tool = tools?.first { $0.name == toolCall.name }

        stream.push(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        var result: AgentToolResult
        var isError = false

        do {
            guard let tool else { throw NSError(domain: "AgentTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tool \(toolCall.name) not found"]) }
            let validatedArgs = try validateToolArguments(tool: tool.aiTool, toolCall: toolCall)
            result = try await tool.execute(toolCall.id, validatedArgs, signal) { partialResult in
                stream.push(.toolExecutionUpdate(
                    toolCallId: toolCall.id,
                    toolName: toolCall.name,
                    args: toolCall.arguments,
                    partialResult: partialResult
                ))
            }
        } catch {
            let message = error.localizedDescription
            result = AgentToolResult(
                content: [.text(TextContent(text: message))],
                details: AnyCodable([String: Any]())
            )
            isError = true
        }

        stream.push(.toolExecutionEnd(
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            result: result,
            isError: isError
        ))

        let toolResultMessage = ToolResultMessage(
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            content: result.content,
            details: result.details,
            isError: isError
        )

        results.append(toolResultMessage)
        stream.push(.messageStart(message: .toolResult(toolResultMessage)))
        stream.push(.messageEnd(message: .toolResult(toolResultMessage)))

        if let getSteeringMessages {
            let queued = await getSteeringMessages()
            if !queued.isEmpty {
                steeringMessages = queued
                let remaining = toolCalls[(index + 1)...]
                for skipped in remaining {
                    results.append(skipToolCall(skipped, stream: stream))
                }
                break
            }
        }
    }

    return (results, steeringMessages)
}

private func skipToolCall(
    _ toolCall: ToolCall,
    stream: EventStream<AgentEvent, [AgentMessage]>
) -> ToolResultMessage {
    let result = AgentToolResult(
        content: [.text(TextContent(text: "Skipped due to queued user message."))],
        details: AnyCodable([String: Any]())
    )

    stream.push(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
    stream.push(.toolExecutionEnd(toolCallId: toolCall.id, toolName: toolCall.name, result: result, isError: true))

    let toolResultMessage = ToolResultMessage(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        content: result.content,
        details: result.details,
        isError: true
    )

    stream.push(.messageStart(message: .toolResult(toolResultMessage)))
    stream.push(.messageEnd(message: .toolResult(toolResultMessage)))

    return toolResultMessage
}

private func buildErrorAssistantMessage(model: Model, reason: StopReason, message: String) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: ""))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: reason,
        errorMessage: message
    )
}
