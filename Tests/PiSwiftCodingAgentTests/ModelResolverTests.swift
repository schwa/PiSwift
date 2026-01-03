import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func mockModels() -> [Model] {
    let mockModels: [Model] = [
        Model(
            id: "claude-sonnet-4-5",
            name: "Claude Sonnet 4.5",
            api: .anthropicMessages,
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            contextWindow: 200000,
            maxTokens: 8192
        ),
        Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: .anthropicMessages,
            provider: "openai",
            baseUrl: "https://api.openai.com",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
            contextWindow: 128000,
            maxTokens: 4096
        ),
        Model(
            id: "qwen/qwen3-coder:exacto",
            name: "Qwen3 Coder Exacto",
            api: .anthropicMessages,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1),
            contextWindow: 128000,
            maxTokens: 8192
        ),
        Model(
            id: "openai/gpt-4o:extended",
            name: "GPT-4o Extended",
            api: .anthropicMessages,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
            contextWindow: 128000,
            maxTokens: 4096
        ),
    ]
    return mockModels
}

@Test func parseModelPatternSimple() {
    let models = mockModels()
    let exact = parseModelPattern("claude-sonnet-4-5", models)
    #expect(exact.model?.id == "claude-sonnet-4-5")
    #expect(exact.thinkingLevel == .off)
    #expect(exact.warning == nil)

    let partial = parseModelPattern("sonnet", models)
    #expect(partial.model?.id == "claude-sonnet-4-5")
    #expect(partial.thinkingLevel == .off)

    let missing = parseModelPattern("nonexistent", models)
    #expect(missing.model == nil)
    #expect(missing.thinkingLevel == .off)
}

@Test func parseModelPatternThinkingLevels() {
    let models = mockModels()
    let high = parseModelPattern("sonnet:high", models)
    #expect(high.model?.id == "claude-sonnet-4-5")
    #expect(high.thinkingLevel == .high)
    #expect(high.warning == nil)

    let medium = parseModelPattern("gpt-4o:medium", models)
    #expect(medium.model?.id == "gpt-4o")
    #expect(medium.thinkingLevel == .medium)

    for level in ["off", "minimal", "low", "medium", "high", "xhigh"] {
        let result = parseModelPattern("sonnet:\(level)", models)
        #expect(result.model?.id == "claude-sonnet-4-5")
        #expect(result.thinkingLevel.rawValue == level)
        #expect(result.warning == nil)
    }
}

@Test func parseModelPatternInvalidThinking() {
    let models = mockModels()
    let result = parseModelPattern("sonnet:random", models)
    #expect(result.model?.id == "claude-sonnet-4-5")
    #expect(result.thinkingLevel == .off)
    #expect(result.warning?.contains("Invalid thinking level") == true)

    let result2 = parseModelPattern("gpt-4o:invalid", models)
    #expect(result2.model?.id == "gpt-4o")
    #expect(result2.warning?.contains("Invalid thinking level") == true)
}

@Test func parseModelPatternOpenRouter() {
    let models = mockModels()
    let qwen = parseModelPattern("qwen/qwen3-coder:exacto", models)
    #expect(qwen.model?.id == "qwen/qwen3-coder:exacto")
    #expect(qwen.thinkingLevel == .off)

    let qwenProvider = parseModelPattern("openrouter/qwen/qwen3-coder:exacto", models)
    #expect(qwenProvider.model?.id == "qwen/qwen3-coder:exacto")
    #expect(qwenProvider.model?.provider == "openrouter")

    let qwenHigh = parseModelPattern("qwen/qwen3-coder:exacto:high", models)
    #expect(qwenHigh.thinkingLevel == .high)

    let qwenProviderHigh = parseModelPattern("openrouter/qwen/qwen3-coder:exacto:high", models)
    #expect(qwenProviderHigh.thinkingLevel == .high)

    let extended = parseModelPattern("openai/gpt-4o:extended", models)
    #expect(extended.model?.id == "openai/gpt-4o:extended")
}

@Test func parseModelPatternInvalidOpenRouterThinking() {
    let models = mockModels()
    let result = parseModelPattern("qwen/qwen3-coder:exacto:random", models)
    #expect(result.model?.id == "qwen/qwen3-coder:exacto")
    #expect(result.thinkingLevel == .off)
    #expect(result.warning?.contains("Invalid thinking level") == true)

    let result2 = parseModelPattern("qwen/qwen3-coder:exacto:high:random", models)
    #expect(result2.model?.id == "qwen/qwen3-coder:exacto")
    #expect(result2.thinkingLevel == .off)
    #expect(result2.warning?.contains("Invalid thinking level") == true)
}

@Test func parseModelPatternEdgeCases() {
    let models = mockModels()
    let empty = parseModelPattern("", models)
    #expect(empty.model != nil)
    #expect(empty.thinkingLevel == .off)

    let trailing = parseModelPattern("sonnet:", models)
    #expect(trailing.model?.id == "claude-sonnet-4-5")
    #expect(trailing.warning?.contains("Invalid thinking level") == true)
}
