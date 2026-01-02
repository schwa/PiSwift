import Foundation
import OpenAI

public func streamOpenAIResponses(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
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
            let client = try makeOpenAIClient(model: model, apiKey: options.apiKey)
            let query = try buildResponsesQuery(model: model, context: context, options: options)
            let openAIStream: AsyncThrowingStream<ResponseStreamEvent, Error> = client.responses.createResponseStreaming(query: query)
            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var currentToolCallArgs = ""

            func startBlock(kind: String, block: ContentBlock) {
                output.content.append(block)
                currentBlockIndex = output.content.count - 1
                currentBlockKind = kind
                switch block {
                case .text:
                    stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                case .thinking:
                    stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                case .toolCall:
                    stream.push(.toolCallStart(contentIndex: currentBlockIndex!, partial: output))
                default:
                    break
                }
            }

            func finishCurrentBlock() {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let textContent):
                    stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: output))
                case .thinking(let thinkingContent):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: output))
                case .toolCall(var toolCall):
                    toolCall.arguments = parseStreamingJSON(currentToolCallArgs)
                    output.content[index] = .toolCall(toolCall)
                    stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: output))
                default:
                    break
                }
                currentBlockIndex = nil
                currentBlockKind = nil
                currentToolCallArgs = ""
            }

            for try await event in openAIStream {
                if options.signal?.isCancelled == true {
                    throw OpenAIResponsesStreamError.aborted
                }

                switch event {
                case .outputItem(let itemEvent):
                    switch itemEvent {
                    case .added(let added):
                        switch added.item {
                        case .reasoning:
                            finishCurrentBlock()
                            startBlock(kind: "thinking", block: .thinking(ThinkingContent(thinking: "")))
                        case .outputMessage:
                            finishCurrentBlock()
                            startBlock(kind: "text", block: .text(TextContent(text: "")))
                        case .functionToolCall(let toolCall):
                            finishCurrentBlock()
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let call = ToolCall(id: combinedId, name: toolCall.name, arguments: [:])
                            currentToolCallArgs = toolCall.arguments
                            startBlock(kind: "toolCall", block: .toolCall(call))
                        default:
                            break
                        }
                    case .done(let doneEvent):
                        switch doneEvent.item {
                        case .reasoning(let reasoningItem):
                            if currentBlockKind == "thinking", let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
                                if let data = try? JSONEncoder().encode(reasoningItem),
                                   let signature = String(data: data, encoding: .utf8) {
                                    thinking.thinkingSignature = signature
                                    output.content[index] = .thinking(thinking)
                                }
                                stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                                currentBlockIndex = nil
                                currentBlockKind = nil
                            }
                        case .outputMessage(let message):
                            if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
                                text.textSignature = message.id
                                output.content[index] = .text(text)
                                stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                                currentBlockIndex = nil
                                currentBlockKind = nil
                            }
                        case .functionToolCall(let toolCall):
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let arguments = parseJSONStringArguments(toolCall.arguments)
                            let call = ToolCall(id: combinedId, name: toolCall.name, arguments: arguments)
                            if let index = currentBlockIndex {
                                output.content[index] = .toolCall(call)
                                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: output))
                                currentBlockIndex = nil
                                currentBlockKind = nil
                            }
                        default:
                            break
                        }
                    }
                case .reasoningSummaryText(let summaryEvent):
                    switch summaryEvent {
                    case .delta(let deltaEvent):
                        if currentBlockKind == "thinking", let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
                            thinking.thinking += deltaEvent.delta
                            output.content[index] = .thinking(thinking)
                            stream.push(.thinkingDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .outputText(let outputTextEvent):
                    switch outputTextEvent {
                    case .delta(let deltaEvent):
                        if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
                            text.text += deltaEvent.delta
                            output.content[index] = .text(text)
                            stream.push(.textDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .refusal(let refusalEvent):
                    switch refusalEvent {
                    case .delta(let deltaEvent):
                        if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
                            text.text += deltaEvent.delta
                            output.content[index] = .text(text)
                            stream.push(.textDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .functionCallArguments(let argumentsEvent):
                    switch argumentsEvent {
                    case .delta(let deltaEvent):
                        if currentBlockKind == "toolCall", let index = currentBlockIndex, case .toolCall(var tool) = output.content[index] {
                            currentToolCallArgs += deltaEvent.delta
                            tool.arguments = parseStreamingJSON(currentToolCallArgs)
                            output.content[index] = .toolCall(tool)
                            stream.push(.toolCallDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .completed(let completed):
                    if let usage = completed.response.usage {
                        let cached = usage.inputTokensDetails.cachedTokens
                        output.usage = Usage(
                            input: usage.inputTokens - cached,
                            output: usage.outputTokens,
                            cacheRead: cached,
                            cacheWrite: 0,
                            totalTokens: usage.totalTokens
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                    output.stopReason = mapResponsesStopReason(completed.response.status)
                    if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) && output.stopReason == .stop {
                        output.stopReason = .toolUse
                    }
                case .failed:
                    throw OpenAIResponsesStreamError.unknown
                case .error(let errorEvent):
                    throw OpenAIResponsesStreamError.apiError(errorEvent.message)
                default:
                    break
                }
            }

            finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw OpenAIResponsesStreamError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw OpenAIResponsesStreamError.unknown
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

private func buildResponsesQuery(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
) throws -> CreateModelResponseQuery {
    let inputItems = convertResponsesMessages(model: model, context: context)

    var reasoning: Components.Schemas.Reasoning? = nil
    var include: [Components.Schemas.Includable]? = nil
    if model.reasoning {
        if options.reasoningEffort != nil || options.reasoningSummary != nil {
            reasoning = Components.Schemas.Reasoning(
                effort: mapResponsesReasoningEffort(options.reasoningEffort),
                summary: mapReasoningSummary(options.reasoningSummary)
            )
            include = [.reasoning_encryptedContent]
        }
    }

    let tools = context.tools.map(convertResponsesTools)

    return CreateModelResponseQuery(
        input: .inputItemList(inputItems),
        model: model.id,
        include: include,
        instructions: nil,
        maxOutputTokens: options.maxTokens,
        reasoning: reasoning,
        store: nil,
        stream: true,
        temperature: options.temperature,
        toolChoice: nil,
        tools: tools
    )
}

private func mapResponsesReasoningEffort(_ effort: ReasoningEffort?) -> Components.Schemas.ReasoningEffort? {
    guard let effort else { return nil }
    switch effort {
    case .minimal:
        return .minimal
    case .low:
        return .low
    case .medium:
        return .medium
    case .high, .xhigh:
        return .high
    }
}

private func mapReasoningSummary(_ summary: OpenAIReasoningSummary?) -> Components.Schemas.Reasoning.SummaryPayload? {
    switch summary {
    case .auto:
        return .auto
    case .concise:
        return .concise
    case .detailed:
        return .detailed
    case .none:
        return nil
    }
}

private func convertResponsesMessages(model: Model, context: Context) -> [InputItem] {
    var messages: [InputItem] = []
    let transformed = transformMessages(context.messages, model: model)

    if let systemPrompt = context.systemPrompt {
        let role: EasyInputMessage.RolePayload = model.reasoning ? .developer : .system
        let message = EasyInputMessage(role: role, content: .textInput(sanitizeSurrogates(systemPrompt)))
        messages.append(.inputMessage(message))
    }

    var messageIndex = 0
    for msg in transformed {
        switch msg {
        case .user(let user):
            switch user.content {
            case .text(let text):
                messages.append(.inputMessage(EasyInputMessage(role: .user, content: .textInput(sanitizeSurrogates(text)))))
            case .blocks(let blocks):
                let contents = blocks.compactMap { block -> InputContent? in
                    switch block {
                    case .text(let textContent):
                        return .inputText(Components.Schemas.InputTextContent(_type: .inputText, text: sanitizeSurrogates(textContent.text)))
                    case .image(let imageContent):
                        return .inputImage(InputImage(_type: .inputImage, imageUrl: "data:\(imageContent.mimeType);base64,\(imageContent.data)", detail: .auto))
                    default:
                        return nil
                    }
                }
                let filtered = model.input.contains(.image) ? contents : contents.filter {
                    if case .inputImage = $0 { return false }
                    return true
                }
                if !filtered.isEmpty {
                    messages.append(.inputMessage(EasyInputMessage(role: .user, content: .inputItemContentList(filtered))))
                }
            }
        case .assistant(let assistant):
            var items: [InputItem] = []
            for block in assistant.content {
                switch block {
                case .text(let textBlock):
                    let id = textBlock.textSignature ?? "msg_\(messageIndex)"
                    let content = Components.Schemas.OutputTextContent(_type: .outputText, text: sanitizeSurrogates(textBlock.text), annotations: [])
                    let outputMessage = Components.Schemas.OutputMessage(
                        id: id,
                        _type: .message,
                        role: .assistant,
                        content: [.OutputTextContent(content)],
                        status: .completed
                    )
                    items.append(.item(.outputMessage(outputMessage)))
                case .toolCall(let toolCall):
                    let parts = toolCall.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let callId = parts.first.map(String.init) ?? toolCall.id
                    let itemId = parts.count > 1 ? String(parts[1]) : nil
                    let toolItem = Components.Schemas.FunctionToolCall(
                        id: itemId,
                        _type: .functionCall,
                        callId: callId,
                        name: toolCall.name,
                        arguments: jsonString(from: toolCall.arguments),
                        status: .completed
                    )
                    items.append(.item(.functionToolCall(toolItem)))
                case .thinking:
                    break
                case .image:
                    break
                }
            }
            if !items.isEmpty {
                messages.append(contentsOf: items)
            }
        case .toolResult(let toolResult):
            let textResult = toolResult.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined(separator: "\n")
            let hasImages = toolResult.content.contains { block in
                if case .image = block { return true }
                return false
            }

            let callId = toolResult.toolCallId.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? toolResult.toolCallId
            let toolOutput = Components.Schemas.FunctionCallOutputItemParam(
                callId: callId,
                _type: .functionCallOutput,
                output: sanitizeSurrogates(textResult.isEmpty ? "(see attached image)" : textResult)
            )
            messages.append(.item(.functionCallOutputItemParam(toolOutput)))

            if hasImages && model.input.contains(.image) {
                var contentParts: [InputContent] = [
                    .inputText(Components.Schemas.InputTextContent(_type: .inputText, text: "Attached image(s) from tool result:"))
                ]
                for block in toolResult.content {
                    if case .image(let image) = block {
                        contentParts.append(.inputImage(InputImage(_type: .inputImage, imageUrl: "data:\(image.mimeType);base64,\(image.data)", detail: .auto)))
                    }
                }
                messages.append(.inputMessage(EasyInputMessage(role: .user, content: .inputItemContentList(contentParts))))
            }
        }
        messageIndex += 1
    }

    return messages
}

private func convertResponsesTools(_ tools: [AITool]) -> [Tool] {
    tools.compactMap { tool in
        let schema = openAIJSONSchema(from: tool.parameters) ?? .object([:])
        let function = FunctionTool(name: tool.name, description: tool.description, parameters: schema, strict: false)
        return .functionTool(function)
    }
}

private func parseJSONStringArguments(_ json: String) -> [String: AnyCodable] {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object.mapValues { AnyCodable($0) }
}

private func mapResponsesStopReason(_ status: String) -> StopReason {
    switch status {
    case "completed":
        return .stop
    case "incomplete":
        return .length
    case "failed", "cancelled":
        return .error
    case "in_progress", "queued":
        return .stop
    default:
        return .stop
    }
}

private enum OpenAIResponsesStreamError: Error {
    case aborted
    case unknown
    case apiError(String)
}
