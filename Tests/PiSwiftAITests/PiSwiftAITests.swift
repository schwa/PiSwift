import Foundation
import Testing
import PiSwiftAI

private let RUN_ANTHROPIC_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_ANTHROPIC_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

@Test func sanitizeSurrogatesRemovesUnpaired() {
    let unpaired = String(decoding: [0xD83D], as: UTF16.self)
    let input = "Hello \(unpaired) World"
    let sanitized = sanitizeSurrogates(input)
    #expect(!sanitized.contains(unpaired))
    #expect(sanitized == "Hello  World")
}

@Test func transformMessagesInsertsSyntheticToolResult() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let toolCall = ToolCall(id: "call_1", name: "get_weather", arguments: [:])
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let user = UserMessage(content: .text("continue"))
    let transformed = transformMessages([.assistant(assistant), .user(user)], model: model)

    #expect(transformed.count == 3)
    guard case .toolResult(let toolResult) = transformed[1] else {
        #expect(Bool(false), "Expected synthetic tool result message")
        return
    }
    #expect(toolResult.toolCallId == "call_1")
    #expect(toolResult.isError)
}

@Test func contextOverflowDetection() {
    let usage = Usage(input: 10, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 10)
    let message = AssistantMessage(
        content: [],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: usage,
        stopReason: .error,
        errorMessage: "Your input exceeds the context window of this model"
    )
    #expect(isContextOverflow(message))
}

@Test func openAICompletionsSmoke() async throws {
    guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let context = Context(messages: [.user(UserMessage(content: .text("Say hello in one word.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func openAIResponsesSmoke() async throws {
    guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .openai, modelId: "gpt-5-mini")
    let context = Context(messages: [.user(UserMessage(content: .text("Return the word ok.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func anthropicSmoke() async throws {
    guard RUN_ANTHROPIC_TESTS else {
        return
    }
    let model = getModel(provider: .anthropic, modelId: "claude-3-5-haiku-20241022")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}
