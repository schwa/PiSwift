import Foundation

internal let ModelsData: [String: [String: Model]] = [
    "openai": [
        "gpt-4o-mini": Model(
            id: "gpt-4o-mini",
            name: "GPT-4o mini",
            api: .openAICompletions,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 0.15, output: 0.6, cacheRead: 0.08, cacheWrite: 0),
            contextWindow: 128000,
            maxTokens: 16384
        ),
        "gpt-5-mini": Model(
            id: "gpt-5-mini",
            name: "GPT-5 Mini",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 0.25, output: 2, cacheRead: 0.03, cacheWrite: 0),
            contextWindow: 400000,
            maxTokens: 128000
        ),
        "gpt-5": Model(
            id: "gpt-5",
            name: "GPT-5",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 1.25, output: 10, cacheRead: 0.13, cacheWrite: 0),
            contextWindow: 400000,
            maxTokens: 128000
        ),
        "gpt-5.1-codex-max": Model(
            id: "gpt-5.1-codex-max",
            name: "GPT-5.1 Codex Max",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
            contextWindow: 400000,
            maxTokens: 128000
        ),
        "gpt-5.2": Model(
            id: "gpt-5.2",
            name: "GPT-5.2",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0),
            contextWindow: 400000,
            maxTokens: 128000
        ),
    ],
    "anthropic": [
        "claude-3-5-haiku-20241022": Model(
            id: "claude-3-5-haiku-20241022",
            name: "Claude Haiku 3.5",
            api: .anthropicMessages,
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
            contextWindow: 200000,
            maxTokens: 8192
        ),
        "claude-3-5-haiku-latest": Model(
            id: "claude-3-5-haiku-latest",
            name: "Claude Haiku 3.5 (latest)",
            api: .anthropicMessages,
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
            contextWindow: 200000,
            maxTokens: 8192
        )
    ]
]
