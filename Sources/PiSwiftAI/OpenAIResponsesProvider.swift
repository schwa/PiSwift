import CryptoKit
import Foundation
import OpenAI

public func streamOpenAIResponses(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
) -> AssistantMessageEventStream {
    if model.provider.lowercased() == "openai-codex" {
        let codexOptions = OpenAICodexResponsesOptions(
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            signal: options.signal,
            apiKey: options.apiKey,
            reasoningEffort: options.reasoningEffort,
            reasoningSummary: mapCodexReasoningSummary(options.reasoningSummary),
            sessionId: options.sessionId
        )
        return streamOpenAICodexResponses(model: model, context: context, options: codexOptions)
    }

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
        var client: OpenAI? = nil
        var query: CreateModelResponseQuery? = nil

        do {
            let builtClient = try makeOpenAIClient(model: model, apiKey: options.apiKey)
            let builtQuery = try buildResponsesQuery(model: model, context: context, options: options)
            client = builtClient
            query = builtQuery
            let openAIStream: AsyncThrowingStream<ResponseStreamEvent, Error> = builtClient.responses.createResponseStreaming(query: builtQuery)
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
            if shouldLogOpenAIErrorBody(), let client, let query, error is OpenAIError {
                await debugOpenAIResponsesError(client: client, query: query)
            }
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = describeOpenAIError(error)
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
    var inputItems = convertResponsesMessages(model: model, context: context)

    var reasoning: Components.Schemas.Reasoning? = nil
    var include: [Components.Schemas.Includable]? = nil
    if model.reasoning {
        if options.reasoningEffort != nil || options.reasoningSummary != nil {
            reasoning = Components.Schemas.Reasoning(
                effort: mapResponsesReasoningEffort(options.reasoningEffort),
                summary: mapReasoningSummary(options.reasoningSummary)
            )
            include = [.reasoning_encryptedContent]
        } else if model.id.hasPrefix("gpt-5") {
            let note = EasyInputMessage(role: .developer, content: .textInput(sanitizeSurrogates("# Juice: 0 !important")))
            inputItems.append(.inputMessage(note))
        }
    }

    let tools = context.tools.map(convertResponsesTools)

    let query = CreateModelResponseQuery(
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
    logOpenAIResponsesQuery(query)
    return query
}

private func mapResponsesReasoningEffort(_ effort: ThinkingLevel?) -> Components.Schemas.ReasoningEffort? {
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

private func mapCodexReasoningSummary(_ summary: OpenAIReasoningSummary?) -> OpenAICodexReasoningSummary? {
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
            let allowToolCalls = assistant.stopReason != .error
            for block in assistant.content {
                switch block {
                case .text(let textBlock):
                    let id = normalizeResponseItemId(textBlock.textSignature, fallbackIndex: messageIndex)
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
                    guard allowToolCalls else { break }
                    let parts = toolCall.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let callId = parts.first.map(String.init) ?? toolCall.id
                    let rawItemId = parts.count > 1 ? String(parts[1]) : nil
                    let itemId = normalizeOptionalResponseItemId(rawItemId)
                    let toolItem = Components.Schemas.FunctionToolCall(
                        id: itemId,
                        _type: .functionCall,
                        callId: callId,
                        name: toolCall.name,
                        arguments: jsonString(from: toolCall.arguments),
                        status: .completed
                    )
                    items.append(.item(.functionToolCall(toolItem)))
                case .thinking(let thinking):
                    guard allowToolCalls else { break }
                    guard let signature = thinking.thinkingSignature,
                          let data = signature.data(using: .utf8) else {
                        break
                    }
                    if let reasoningItem = try? JSONDecoder().decode(Components.Schemas.ReasoningItem.self, from: data) {
                        items.append(.item(.reasoningItem(reasoningItem)))
                    } else {
                        logOpenAIDebug("openai responses failed to decode reasoning item signature")
                    }
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

private func normalizeResponseItemId(_ id: String?, fallbackIndex: Int) -> String {
    var resolved = (id?.isEmpty == false) ? id! : "msg_\(fallbackIndex)"
    if resolved.count > 64 {
        resolved = "msg_\(shortHash(resolved))"
    }
    return resolved
}

private func normalizeOptionalResponseItemId(_ id: String?) -> String? {
    guard let id, !id.isEmpty else { return nil }
    if id.count > 64 {
        return "msg_\(shortHash(id))"
    }
    return id
}

private func shortHash(_ value: String) -> String {
    guard let data = value.data(using: .utf8) else {
        return String(value.prefix(16))
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
}

private func shouldLogOpenAIPayload() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = env["PI_DEBUG_OPENAI_PAYLOAD"]?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes" || flag == "full"
}

private func shouldLogOpenAIErrorBody() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = env["PI_DEBUG_OPENAI_BODY"]?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

private func logOpenAIResponsesQuery(_ query: CreateModelResponseQuery) {
    guard shouldLogOpenAIDebug() else { return }
    let inputCount: Int
    switch query.input {
    case .textInput:
        inputCount = 1
    case .inputItemList(let items):
        inputCount = items.count
    }
    let toolCount = query.tools?.count ?? 0
    logOpenAIDebug("openai responses query model=\(query.model) inputItems=\(inputCount) tools=\(toolCount) reasoning=\(query.reasoning != nil) stream=\(query.stream == true)")

    guard shouldLogOpenAIPayload() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(query),
       var payload = String(data: data, encoding: .utf8) {
        if payload.count > 20000 {
            payload = String(payload.prefix(20000)) + "\n... (truncated)"
        }
        logOpenAIDebug("openai responses payload=\n\(payload)")
    }
}

private func debugOpenAIResponsesError(client: OpenAI, query: CreateModelResponseQuery) async {
    let nonStreaming = CreateModelResponseQuery(
        input: query.input,
        model: query.model,
        include: query.include,
        background: query.background,
        instructions: query.instructions,
        maxOutputTokens: query.maxOutputTokens,
        metadata: query.metadata,
        parallelToolCalls: query.parallelToolCalls,
        previousResponseId: query.previousResponseId,
        prompt: query.prompt,
        reasoning: query.reasoning,
        serviceTier: query.serviceTier,
        store: query.store,
        stream: false,
        temperature: query.temperature,
        text: query.text,
        toolChoice: query.toolChoice,
        tools: query.tools,
        topP: query.topP,
        truncation: query.truncation,
        user: query.user
    )

    do {
        _ = try await client.responses.createResponse(query: nonStreaming)
    } catch {
        if let apiError = error as? APIErrorResponse {
            logOpenAIDebug("openai errorBody message=\(apiError.error.message) type=\(apiError.error.type) param=\(apiError.error.param ?? "nil") code=\(apiError.error.code ?? "nil")")
        } else {
            logOpenAIDebug("openai nonstreaming error=\(error.localizedDescription)")
        }
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
