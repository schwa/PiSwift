import Foundation
import Testing
@testable import PiSwiftAI

private let RUN_ANTHROPIC_TESTS: Bool = {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_RUN_ANTHROPIC_TESTS"] ?? env["PI_RUN_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}()

final class MockURLProtocol: URLProtocol {
    static let requestHandler = LockedState<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static let allowedHosts = LockedState<Set<String>>([])

    override class func canInit(with request: URLRequest) -> Bool {
        guard requestHandler.withLock({ $0 }) != nil, let host = request.url?.host else { return false }
        return allowedHosts.withLock({ $0.contains(host) })
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func codexTestEvent(type: String, payload: [String: Any]) -> String {
    var event = payload
    event["type"] = type
    guard let data = try? JSONSerialization.data(withJSONObject: event),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

private func readRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data.isEmpty ? nil : data
}

private actor CodexRequestLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if locked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        locked = true
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

private let codexRequestLock = CodexRequestLock()

private struct CodexRequestCapture: Sendable {
    let conversationId: String?
    let sessionId: String?
    let promptCacheKey: String?
}

private func runCodexSessionRequest(sessionId: String?) async throws -> CodexRequestCapture {
    try await codexRequestLock.withLock {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousAgentDir = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", tempDir.path, 1)
        defer {
            if let previousAgentDir {
                setenv("PI_CODING_AGENT_DIR", previousAgentDir, 1)
            } else {
                unsetenv("PI_CODING_AGENT_DIR")
            }
        }

        let payload: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "acc_test"]]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadBase64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "aaa.\(payloadBase64).bbb"

        let seenConversationId = LockedState<String?>(nil)
        let seenSessionId = LockedState<String?>(nil)
        let seenPromptCacheKey = LockedState<String?>(nil)
        MockURLProtocol.allowedHosts.withLock { $0 = ["api.github.com", "raw.githubusercontent.com", "chatgpt.com"] }
        MockURLProtocol.requestHandler.withLock { $0 = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let urlString = url.absoluteString
            if urlString == "https://api.github.com/repos/openai/codex/releases/latest" {
                let data = try JSONSerialization.data(withJSONObject: ["tag_name": "rust-v0.0.0"])
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }

            if urlString.hasPrefix("https://raw.githubusercontent.com/openai/codex/") {
                let data = Data("PROMPT".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["etag": "\"etag\""])!
                return (response, data)
            }

            if urlString == "https://chatgpt.com/backend-api/codex/responses" {
                seenConversationId.withLock { $0 = request.value(forHTTPHeaderField: "conversation_id") }
                seenSessionId.withLock { $0 = request.value(forHTTPHeaderField: "session_id") }
                if let body = readRequestBody(request),
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    seenPromptCacheKey.withLock { $0 = json["prompt_cache_key"] as? String }
                }

                let outputItemAdded = codexTestEvent(
                    type: "response.output_item.added",
                    payload: [
                        "item": [
                            "type": "message",
                            "id": "msg_1",
                            "role": "assistant",
                            "status": "in_progress",
                            "content": [],
                        ],
                    ]
                )
                let outputTextDelta = codexTestEvent(
                    type: "response.output_text.delta",
                    payload: ["delta": "Hello"]
                )
                let outputItemDone = codexTestEvent(
                    type: "response.output_item.done",
                    payload: [
                        "item": [
                            "type": "message",
                            "id": "msg_1",
                            "role": "assistant",
                            "status": "completed",
                            "content": [["type": "output_text", "text": "Hello"]],
                        ],
                    ]
                )
                let responseCompleted = codexTestEvent(
                    type: "response.completed",
                    payload: [
                        "response": [
                            "status": "completed",
                            "usage": [
                                "input_tokens": 5,
                                "output_tokens": 3,
                                "total_tokens": 8,
                                "input_tokens_details": ["cached_tokens": 0],
                            ],
                        ],
                    ]
                )

                let sseEvents = [
                    "data: \(outputItemAdded)",
                    "data: \(outputTextDelta)",
                    "data: \(outputItemDone)",
                    "data: \(responseCompleted)",
                ].joined(separator: "\n\n") + "\n\n"
                let data = Data(sseEvents.utf8)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "text/event-stream"]
                )!
                return (response, data)
            }

            throw URLError(.unsupportedURL)
        } }

        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            MockURLProtocol.requestHandler.withLock { $0 = nil }
            MockURLProtocol.allowedHosts.withLock { $0 = [] }
            URLProtocol.unregisterClass(MockURLProtocol.self)
        }

        let model = getModel(provider: .openaiCodex, modelId: "gpt-5.1")
        let context = Context(messages: [.user(UserMessage(content: .text("Say hello")))])
        let stream = streamOpenAICodexResponses(
            model: model,
            context: context,
            options: OpenAICodexResponsesOptions(apiKey: token, sessionId: sessionId)
        )
        _ = await stream.result()

        return CodexRequestCapture(
            conversationId: seenConversationId.withLock { $0 },
            sessionId: seenSessionId.withLock { $0 },
            promptCacheKey: seenPromptCacheKey.withLock { $0 }
        )
    }
}

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

@Test func transformMessagesNormalizesToolCallIds() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let toolCall = ToolCall(id: "call|abc", name: "do_thing", arguments: [:])
    let assistant = AssistantMessage(
        content: [.toolCall(toolCall)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-3-5-haiku-20241022",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let toolResult = ToolResultMessage(
        toolCallId: "call|abc",
        toolName: "do_thing",
        content: [.text(TextContent(text: "ok"))],
        isError: false,
        timestamp: 0
    )

    let transformed = transformMessages([.assistant(assistant), .toolResult(toolResult)], model: model) { id, _, _ in
        "normalized-\(id)"
    }

    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .toolCall(let transformedCall) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected tool call content")
        return
    }
    #expect(transformedCall.id == "normalized-call|abc")

    guard transformed.count == 2, case .toolResult(let transformedResult) = transformed[1] else {
        #expect(Bool(false), "Expected tool result message")
        return
    }
    #expect(transformedResult.toolCallId == "normalized-call|abc")
}

@Test func transformMessagesPreservesThinkingSignatureForSameModel() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let thinking = ThinkingContent(thinking: "   ", thinkingSignature: "sig")
    let assistant = AssistantMessage(
        content: [.thinking(thinking)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: model)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .thinking(let transformedThinking) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected thinking content")
        return
    }
    #expect(transformedThinking.thinkingSignature == "sig")
}

@Test func transformMessagesConvertsThinkingAcrossProviders() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let thinking = ThinkingContent(thinking: "Reasoning detail", thinkingSignature: "sig")
    let assistant = AssistantMessage(
        content: [.thinking(thinking)],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-3-5-haiku-20241022",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let transformed = transformMessages([.assistant(assistant)], model: model)
    guard case .assistant(let transformedAssistant) = transformed.first else {
        #expect(Bool(false), "Expected assistant message")
        return
    }
    guard case .text(let text) = transformedAssistant.content.first else {
        #expect(Bool(false), "Expected text content")
        return
    }
    #expect(text.text == "Reasoning detail")
}

@Test func transformMessagesSkipsAbortedAssistants() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "ignored"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .aborted
    )
    let user = UserMessage(content: .text("continue"))
    let transformed = transformMessages([.assistant(assistant), .user(user)], model: model)

    #expect(transformed.count == 1)
    guard case .user(let transformedUser) = transformed.first else {
        #expect(Bool(false), "Expected user message")
        return
    }
    guard case .text(let text) = transformedUser.content else {
        #expect(Bool(false), "Expected user text content")
        return
    }
    #expect(text == "continue")
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

@Test func openAICodexSessionIdForwarding() async throws {
    let sessionId = "test-session-123"
    let capture = try await runCodexSessionRequest(sessionId: sessionId)
    #expect(capture.conversationId == sessionId)
    #expect(capture.sessionId == sessionId)
    #expect(capture.promptCacheKey == sessionId)
}

@Test func openAICodexNoSessionId() async throws {
    let capture = try await runCodexSessionRequest(sessionId: nil)
    #expect(capture.conversationId == nil)
    #expect(capture.sessionId == nil)
    #expect(capture.promptCacheKey == nil)
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

@Test func minimaxSmoke() async throws {
    guard ProcessInfo.processInfo.environment["MINIMAX_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .minimax, modelId: "MiniMax-M2.1")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func vercelAiGatewaySmoke() async throws {
    guard ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .vercelAiGateway, modelId: "google/gemini-2.5-flash")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

@Test func zaiSmoke() async throws {
    guard ProcessInfo.processInfo.environment["ZAI_API_KEY"] != nil else {
        return
    }
    let model = getModel(provider: .zai, modelId: "glm-4.5-air")
    let context = Context(messages: [.user(UserMessage(content: .text("Reply with hi.")))])
    let response = try await complete(model: model, context: context)
    #expect(!response.content.isEmpty)
    #expect(response.stopReason != .error)
}

private actor EnvLock {
    func withEnv(_ key: String, value: String?, work: @Sendable () async -> Void) async {
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        await work()
    }
}

private let envLock = EnvLock()

private func withEnv(_ key: String, value: String?, _ work: @Sendable () async -> Void) async {
    await envLock.withEnv(key, value: value, work: work)
}

@Test func openAIPromptCacheRetentionHelper() async throws {
    await withEnv("PI_CACHE_RETENTION", value: nil) {
        #expect(promptCacheRetention(baseUrl: "https://api.openai.com/v1") == nil)
    }
    await withEnv("PI_CACHE_RETENTION", value: "long") {
        #expect(promptCacheRetention(baseUrl: "https://api.openai.com/v1") == "24h")
        #expect(promptCacheRetention(baseUrl: "https://proxy.example.com/v1") == nil)
    }
}

@Test func openAIResponsesCacheMiddlewareInjection() async throws {
    let payload: [String: Any] = [
        "model": "gpt-4o-mini",
        "input": [],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body

    let middleware = OpenAIResponsesCacheMiddleware(sessionId: "session-123", promptCacheRetention: "24h")
    let updated = middleware.intercept(request: request)
    let updatedBody = updated.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedBody?.contains("\"prompt_cache_key\":\"session-123\"") == true)
    #expect(updatedBody?.contains("\"prompt_cache_retention\":\"24h\"") == true)
}

@Test func anthropicCacheRetentionHelper() async throws {
    await withEnv("PI_CACHE_RETENTION", value: nil) {
        #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com") == nil)
    }
    await withEnv("PI_CACHE_RETENTION", value: "long") {
        #expect(anthropicCacheTtl(baseUrl: "https://api.anthropic.com") == "1h")
        #expect(anthropicCacheTtl(baseUrl: "https://proxy.example.com") == nil)
    }
}

@Test func anthropicCacheControlInjection() async throws {
    let payload: [String: Any] = [
        "model": "claude-3-5-haiku-20241022",
        "messages": [
            ["role": "user", "content": "Hello"],
        ],
        "system": "You are a helpful assistant.",
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let updatedDefault = injectCacheControl(body: body, ttl: nil)
    let updatedDefaultString = updatedDefault.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedDefaultString?.contains("\"cache_control\"") == true)
    #expect(updatedDefaultString?.contains("\"ttl\"") == false)

    let updatedLong = injectCacheControl(body: body, ttl: "1h")
    let updatedLongString = updatedLong.flatMap { String(data: $0, encoding: .utf8) }
    #expect(updatedLongString?.contains("\"ttl\":\"1h\"") == true)
}
