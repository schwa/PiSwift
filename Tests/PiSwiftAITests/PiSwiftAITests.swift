import XCTest
import PiSwiftAI

final class PiSwiftAITests: XCTestCase {
    func testSanitizeSurrogatesRemovesUnpaired() {
        let unpaired = String(decoding: [0xD83D], as: UTF16.self)
        let input = "Hello \(unpaired) World"
        let sanitized = sanitizeSurrogates(input)
        XCTAssertFalse(sanitized.contains(unpaired))
        XCTAssertEqual(sanitized, "Hello  World")
    }

    func testTransformMessagesInsertsSyntheticToolResult() {
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

        XCTAssertEqual(transformed.count, 3)
        if case .toolResult(let toolResult) = transformed[1] {
            XCTAssertEqual(toolResult.toolCallId, "call_1")
            XCTAssertTrue(toolResult.isError)
        } else {
            XCTFail("Expected synthetic tool result message")
        }
    }

    func testContextOverflowDetection() {
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
        XCTAssertTrue(isContextOverflow(message))
    }

    func testOpenAICompletionsSmoke() async throws {
        guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
            throw XCTSkip("OPENAI_API_KEY not set")
        }
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let context = Context(messages: [.user(UserMessage(content: .text("Say hello in one word.")))])
        let response = try await complete(model: model, context: context)
        XCTAssertFalse(response.content.isEmpty)
        XCTAssertNotEqual(response.stopReason, .error)
    }

    func testOpenAIResponsesSmoke() async throws {
        guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
            throw XCTSkip("OPENAI_API_KEY not set")
        }
        let model = getModel(provider: .openai, modelId: "gpt-5-mini")
        let context = Context(messages: [.user(UserMessage(content: .text("Return the word ok.")))])
        let response = try await complete(model: model, context: context)
        XCTAssertFalse(response.content.isEmpty)
        XCTAssertNotEqual(response.stopReason, .error)
    }

    func testAnthropicSmoke() async throws {
        guard ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }
        let model = getModel(provider: .anthropic, modelId: "claude-3-5-haiku-20241022")
        let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
        let response = try await complete(model: model, context: context)
        XCTAssertFalse(response.content.isEmpty)
        XCTAssertNotEqual(response.stopReason, .error)
    }
}
