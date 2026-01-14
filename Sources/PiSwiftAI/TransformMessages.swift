import Foundation

private func normalizeToolCallId(_ id: String) -> String {
    let filtered = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    return String(filtered.prefix(40))
}

public func transformMessages(_ messages: [Message], model: Model) -> [Message] {
    var toolCallIdMap: [String: String] = [:]

    let transformed = messages.map { msg -> Message in
        switch msg {
        case .user:
            return msg
        case .toolResult(let toolResult):
            if let normalized = toolCallIdMap[toolResult.toolCallId], normalized != toolResult.toolCallId {
                var updated = toolResult
                updated.toolCallId = normalized
                return .toolResult(updated)
            }
            return msg
        case .assistant(let assistant):
            if assistant.provider == model.provider && assistant.api == model.api {
                return msg
            }

            let targetRequiresStrictIds = model.api == .anthropicMessages || model.provider == "github-copilot"
            let crossProviderSwitch = assistant.provider != model.provider
            let copilotCrossApiSwitch = assistant.provider == "github-copilot" &&
                model.provider == "github-copilot" &&
                assistant.api != model.api
            let needsToolCallIdNormalization = targetRequiresStrictIds && (crossProviderSwitch || copilotCrossApiSwitch)

            let transformedContent: [ContentBlock] = assistant.content.compactMap { block in
                switch block {
                case .thinking(let thinking):
                    let trimmed = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return nil }
                    return .text(TextContent(text: thinking.thinking))
                case .toolCall(let toolCall) where needsToolCallIdNormalization:
                    let normalized = normalizeToolCallId(toolCall.id)
                    if normalized != toolCall.id {
                        toolCallIdMap[toolCall.id] = normalized
                        var updated = toolCall
                        updated.id = normalized
                        return .toolCall(updated)
                    }
                    return block
                default:
                    return block
                }
            }

            var updated = assistant
            updated.content = transformedContent
            return .assistant(updated)
        }
    }

    var result: [Message] = []
    var pendingToolCalls: [ToolCall] = []
    var existingToolResultIds = Set<String>()

    func insertSyntheticToolResults() {
        guard !pendingToolCalls.isEmpty else { return }
        for call in pendingToolCalls where !existingToolResultIds.contains(call.id) {
            let synthetic = ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: "No result provided"))],
                isError: true,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            result.append(.toolResult(synthetic))
        }
        pendingToolCalls = []
        existingToolResultIds = Set<String>()
    }

    for msg in transformed {
        switch msg {
        case .assistant(let assistant):
            if !pendingToolCalls.isEmpty {
                insertSyntheticToolResults()
            }
            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let toolCall) = block {
                    return toolCall
                }
                return nil
            }
            if !toolCalls.isEmpty {
                pendingToolCalls = toolCalls
                existingToolResultIds = Set<String>()
            }
            result.append(msg)
        case .toolResult(let toolResult):
            existingToolResultIds.insert(toolResult.toolCallId)
            result.append(msg)
        case .user:
            if !pendingToolCalls.isEmpty {
                insertSyntheticToolResults()
            }
            result.append(msg)
        }
    }

    return result
}
