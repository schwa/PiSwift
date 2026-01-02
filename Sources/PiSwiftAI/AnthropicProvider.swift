import Foundation
import SwiftAnthropic

public func streamAnthropic(
    model: Model,
    context: Context,
    options: AnthropicOptions
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()

    Task {
        var output = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )

        do {
            let apiKey = options.apiKey ?? ""
            if apiKey.isEmpty {
                throw StreamError.missingApiKey(model.provider)
            }

            let betaHeaders = buildAnthropicBetaHeaders(apiKey: apiKey, interleavedThinking: options.interleavedThinking ?? true)
            let service = AnthropicServiceFactory.service(
                apiKey: apiKey,
                basePath: model.baseUrl,
                betaHeaders: betaHeaders
            )

            let parameters = buildAnthropicParameters(model: model, context: context, options: options)
            let anthropicStream = try await service.streamMessage(parameters)

            stream.push(.start(partial: output))

            var indexMap: [Int: Int] = [:]
            var toolCallPartials: [Int: String] = [:]

            for try await event in anthropicStream {
                if options.signal?.isCancelled == true {
                    throw AnthropicStreamError.aborted
                }

                switch event.streamEvent {
                case .messageStart:
                    if let usage = event.message?.usage {
                        let input = usage.inputTokens ?? 0
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? 0
                        let cacheWrite = usage.cacheCreationInputTokens ?? 0
                        output.usage = Usage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            totalTokens: input + outputTokens + cacheRead + cacheWrite
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                case .contentBlockStart:
                    guard let block = event.contentBlock, let index = event.index else { break }
                    switch block.type {
                    case "text":
                        let textBlock = TextContent(text: "")
                        output.content.append(.text(textBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.textStart(contentIndex: output.content.count - 1, partial: output))
                    case "thinking":
                        let thinkingBlock = ThinkingContent(thinking: "")
                        output.content.append(.thinking(thinkingBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.thinkingStart(contentIndex: output.content.count - 1, partial: output))
                    case "tool_use":
                        let tool = ToolCall(id: block.id ?? "", name: block.name ?? "", arguments: [:])
                        output.content.append(.toolCall(tool))
                        indexMap[index] = output.content.count - 1
                        toolCallPartials[index] = ""
                        stream.push(.toolCallStart(contentIndex: output.content.count - 1, partial: output))
                    default:
                        break
                    }
                case .contentBlockDelta:
                    guard let index = event.index, let contentIndex = indexMap[index] else { break }
                    if let deltaType = event.delta?.type {
                        switch deltaType {
                        case "text_delta":
                            if case .text(var textBlock) = output.content[contentIndex] {
                                let deltaText = event.delta?.text ?? ""
                                textBlock.text += deltaText
                                output.content[contentIndex] = .text(textBlock)
                                stream.push(.textDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "thinking_delta":
                            if case .thinking(var thinkingBlock) = output.content[contentIndex] {
                                let deltaText = event.delta?.thinking ?? ""
                                thinkingBlock.thinking += deltaText
                                output.content[contentIndex] = .thinking(thinkingBlock)
                                stream.push(.thinkingDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "input_json_delta":
                            if case .toolCall(var toolCall) = output.content[contentIndex] {
                                let deltaText = event.delta?.partialJson ?? ""
                                let partial = (toolCallPartials[index] ?? "") + deltaText
                                toolCallPartials[index] = partial
                                toolCall.arguments = parseStreamingJSON(partial)
                                output.content[contentIndex] = .toolCall(toolCall)
                                stream.push(.toolCallDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "signature_delta":
                            if case .thinking(var thinkingBlock) = output.content[contentIndex] {
                                let signature = event.delta?.signature ?? ""
                                thinkingBlock.thinkingSignature = (thinkingBlock.thinkingSignature ?? "") + signature
                                output.content[contentIndex] = .thinking(thinkingBlock)
                            }
                        default:
                            break
                        }
                    }
                case .contentBlockStop:
                    guard let index = event.index, let contentIndex = indexMap[index] else { break }
                    switch output.content[contentIndex] {
                    case .text(let textBlock):
                        stream.push(.textEnd(contentIndex: contentIndex, content: textBlock.text, partial: output))
                    case .thinking(let thinkingBlock):
                        stream.push(.thinkingEnd(contentIndex: contentIndex, content: thinkingBlock.thinking, partial: output))
                    case .toolCall(var toolCall):
                        let partial = toolCallPartials[index] ?? ""
                        toolCall.arguments = parseStreamingJSON(partial)
                        output.content[contentIndex] = .toolCall(toolCall)
                        stream.push(.toolCallEnd(contentIndex: contentIndex, toolCall: toolCall, partial: output))
                    default:
                        break
                    }
                case .messageDelta:
                    if let stopReason = event.delta?.stopReason {
                        output.stopReason = mapAnthropicStopReason(stopReason)
                    }
                    if let usage = event.usage {
                        let input = usage.inputTokens ?? 0
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? 0
                        let cacheWrite = usage.cacheCreationInputTokens ?? 0
                        output.usage = Usage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            totalTokens: input + outputTokens + cacheRead + cacheWrite
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                case .messageStop:
                    break
                case .none:
                    break
                }
            }

            if options.signal?.isCancelled == true {
                throw AnthropicStreamError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw AnthropicStreamError.unknown
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = error.localizedDescription
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private func buildAnthropicParameters(model: Model, context: Context, options: AnthropicOptions) -> MessageParameter {
    let messages = convertAnthropicMessages(model: model, messages: context.messages)
    let maxTokens = options.maxTokens ?? max(model.maxTokens / 3, 1024)

    var system: MessageParameter.System? = nil
    if let prompt = context.systemPrompt {
        system = .text(sanitizeSurrogates(prompt))
    }

    let tools = context.tools.map(convertAnthropicTools)

    let thinking = (options.thinkingEnabled == true && model.reasoning)
        ? MessageParameter.Thinking(budgetTokens: options.thinkingBudgetTokens ?? 1024)
        : nil

    let toolChoice = options.toolChoice.map(convertAnthropicToolChoice)

    let anthroModel = mapAnthropicModel(model.id)

    return MessageParameter(
        model: anthroModel,
        messages: messages,
        maxTokens: maxTokens,
        system: system,
        stream: true,
        temperature: options.temperature,
        tools: tools,
        toolChoice: toolChoice,
        thinking: thinking
    )
}

private func mapAnthropicModel(_ id: String) -> SwiftAnthropic.Model {
    switch id {
    case "claude-3-5-haiku-latest":
        return .claude35Haiku
    default:
        return .other(id)
    }
}

private func buildAnthropicBetaHeaders(apiKey: String, interleavedThinking: Bool) -> [String]? {
    var headers = ["fine-grained-tool-streaming-2025-05-14"]
    if interleavedThinking {
        headers.append("interleaved-thinking-2025-05-14")
    }
    if apiKey.contains("sk-ant-oat") {
        headers.insert("oauth-2025-04-20", at: 0)
    }
    return headers
}

private func convertAnthropicMessages(model: Model, messages: [Message]) -> [MessageParameter.Message] {
    let transformed = transformMessages(messages, model: model)
    var params: [MessageParameter.Message] = []

    var index = 0
    while index < transformed.count {
        let msg = transformed[index]
        switch msg {
        case .user(let user):
            let content = convertUserContent(model: model, content: user.content)
            if let content {
                params.append(MessageParameter.Message(role: .user, content: content))
            }
        case .assistant(let assistant):
            let contentObjects = convertAssistantContent(assistant)
            if !contentObjects.isEmpty {
                params.append(MessageParameter.Message(role: .assistant, content: .list(contentObjects)))
            }
        case .toolResult(let toolResult):
            var toolResults: [MessageParameter.Message.Content.ContentObject] = []
            var imageBlocks: [ImageContent] = []
            toolResults.append(convertToolResultContent(toolResult: toolResult))
            imageBlocks.append(contentsOf: toolResult.content.compactMap { block in
                if case .image(let image) = block { return image }
                return nil
            })

            var lookahead = index + 1
            while lookahead < transformed.count {
                if case .toolResult(let next) = transformed[lookahead] {
                    toolResults.append(convertToolResultContent(toolResult: next))
                    imageBlocks.append(contentsOf: next.content.compactMap { block in
                        if case .image(let image) = block { return image }
                        return nil
                    })
                    lookahead += 1
                } else {
                    break
                }
            }
            index = lookahead - 1
            params.append(MessageParameter.Message(role: .user, content: .list(toolResults)))

            if !imageBlocks.isEmpty && model.input.contains(.image) {
                var imageContent: [MessageParameter.Message.Content.ContentObject] = [
                    .text("Attached image(s) from tool result:")
                ]
                for image in imageBlocks {
                    if let media = anthropicMediaType(from: image.mimeType) {
                        let source = MessageParameter.Message.Content.ImageSource(type: .base64, mediaType: media, data: image.data)
                        imageContent.append(.image(source))
                    }
                }
                params.append(MessageParameter.Message(role: .user, content: .list(imageContent)))
            }
        }
        index += 1
    }

    return params
}

private func convertUserContent(model: Model, content: UserContent) -> MessageParameter.Message.Content? {
    switch content {
    case .text(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return .text(sanitizeSurrogates(text))
    case .blocks(let blocks):
        var objects: [MessageParameter.Message.Content.ContentObject] = []
        for block in blocks {
            switch block {
            case .text(let textBlock):
                let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                objects.append(.text(sanitizeSurrogates(textBlock.text)))
            case .image(let imageBlock):
                if model.input.contains(.image), let media = anthropicMediaType(from: imageBlock.mimeType) {
                    let source = MessageParameter.Message.Content.ImageSource(type: .base64, mediaType: media, data: imageBlock.data)
                    objects.append(.image(source))
                }
            default:
                continue
            }
        }
        if objects.isEmpty { return nil }
        return .list(objects)
    }
}

private func convertAssistantContent(_ assistant: AssistantMessage) -> [MessageParameter.Message.Content.ContentObject] {
    var objects: [MessageParameter.Message.Content.ContentObject] = []
    for block in assistant.content {
        switch block {
        case .text(let textBlock):
            let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            objects.append(.text(sanitizeSurrogates(textBlock.text)))
        case .thinking(let thinkingBlock):
            let trimmed = thinkingBlock.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let signature = thinkingBlock.thinkingSignature, !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                objects.append(.thinking(sanitizeSurrogates(thinkingBlock.thinking), signature))
            } else {
                objects.append(.text(sanitizeSurrogates(thinkingBlock.thinking)))
            }
        case .toolCall(let toolCall):
            let toolInput = convertToolArguments(toolCall.arguments)
            objects.append(.toolUse(sanitizeToolCallId(toolCall.id), toolCall.name, toolInput))
        default:
            continue
        }
    }
    return objects
}

private func convertToolResultContent(toolResult: ToolResultMessage) -> MessageParameter.Message.Content.ContentObject {
    let textResult = toolResult.content.compactMap { block -> String? in
        if case .text(let textBlock) = block { return textBlock.text }
        return nil
    }.joined(separator: "\n")
    let content = sanitizeSurrogates(textResult.isEmpty ? "(see attached image)" : textResult)
    let toolResultObject = MessageParameter.Message.Content.ContentObject.toolResult(
        sanitizeToolCallId(toolResult.toolCallId),
        content,
        isError: toolResult.isError
    )
    return toolResultObject
}

private func convertAnthropicTools(_ tools: [AITool]) -> [MessageParameter.Tool] {
    tools.compactMap { tool in
        let schema = anthropicJSONSchema(from: tool.parameters)
        return .function(name: tool.name, description: tool.description, inputSchema: schema)
    }
}

private func anthropicJSONSchema(from parameters: [String: AnyCodable]) -> JSONSchema? {
    let jsonObject = parameters.mapValues { $0.jsonValue }
    guard JSONSerialization.isValidJSONObject(jsonObject),
          let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []) else {
        return nil
    }
    return try? JSONDecoder().decode(JSONSchema.self, from: data)
}

private func convertAnthropicToolChoice(_ choice: AnthropicToolChoice) -> MessageParameter.ToolChoice {
    switch choice {
    case .auto:
        return .init(type: .auto)
    case .any:
        return .init(type: .any)
    case .none:
        return .init(type: .auto, disableParallelToolUse: true)
    case .tool(let name):
        return .init(type: .tool, name: name)
    }
}

private func mapAnthropicStopReason(_ reason: String) -> StopReason {
    switch reason {
    case "end_turn":
        return .stop
    case "max_tokens":
        return .length
    case "tool_use":
        return .toolUse
    case "refusal":
        return .error
    case "pause_turn":
        return .stop
    case "stop_sequence":
        return .stop
    default:
        return .stop
    }
}

private func sanitizeToolCallId(_ id: String) -> String {
    let allowed = id.map { char -> Character in
        if char.isLetter || char.isNumber || char == "_" || char == "-" {
            return char
        }
        return "_"
    }
    return String(allowed)
}

private func convertToolArguments(_ arguments: [String: AnyCodable]) -> MessageResponse.Content.Input {
    arguments.mapValues { convertDynamicContent($0.value) }
}

private func convertDynamicContent(_ value: Any) -> MessageResponse.Content.DynamicContent {
    switch value {
    case is NSNull:
        return .null
    case let intVal as Int:
        return .integer(intVal)
    case let doubleVal as Double:
        return .double(doubleVal)
    case let stringVal as String:
        return .string(stringVal)
    case let boolVal as Bool:
        return .bool(boolVal)
    case let arrayVal as [Any]:
        return .array(arrayVal.map { convertDynamicContent($0) })
    case let dictVal as [String: Any]:
        return .dictionary(dictVal.mapValues { convertDynamicContent($0) })
    default:
        return .string(String(describing: value))
    }
}

private func anthropicMediaType(from mimeType: String) -> MessageParameter.Message.Content.ImageSource.MediaType? {
    switch mimeType {
    case "image/jpeg", "image/jpg":
        return .jpeg
    case "image/png":
        return .png
    case "image/gif":
        return .gif
    case "image/webp":
        return .webp
    default:
        return nil
    }
}

private enum AnthropicStreamError: Error {
    case aborted
    case unknown
}
