import Foundation

public func getEnvApiKey(provider: KnownProvider) -> String? {
    getEnvApiKey(provider: provider.rawValue)
}

public func getEnvApiKey(provider: String) -> String? {
    let env = ProcessInfo.processInfo.environment

    if provider == "anthropic" {
        return env["ANTHROPIC_OAUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"]
    }

    if provider == "openai" {
        return env["OPENAI_API_KEY"]
    }

    return nil
}

public func stream(model: Model, context: Context, options: StreamOptions? = nil) throws -> AssistantMessageEventStream {
    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        throw StreamError.missingApiKey(model.provider)
    }

    switch model.api {
    case .openAICompletions:
        let providerOptions = OpenAICompletionsOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey
        )
        return streamOpenAICompletions(model: model, context: context, options: providerOptions)
    case .openAIResponses:
        let providerOptions = OpenAIResponsesOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey
        )
        return streamOpenAIResponses(model: model, context: context, options: providerOptions)
    case .anthropicMessages:
        let providerOptions = AnthropicOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey
        )
        return streamAnthropic(model: model, context: context, options: providerOptions)
    }
}

public func complete(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try stream(model: model, context: context, options: options)
    return await stream.result()
}

public func streamSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) throws -> AssistantMessageEventStream {
    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        throw StreamError.missingApiKey(model.provider)
    }

    switch model.api {
    case .anthropicMessages:
        let providerOptions = mapAnthropicOptions(model: model, options: options, apiKey: apiKey)
        return streamAnthropic(model: model, context: context, options: providerOptions)
    case .openAICompletions:
        let providerOptions = mapOpenAICompletionsOptions(model: model, options: options, apiKey: apiKey)
        return streamOpenAICompletions(model: model, context: context, options: providerOptions)
    case .openAIResponses:
        let providerOptions = mapOpenAIResponsesOptions(model: model, options: options, apiKey: apiKey)
        return streamOpenAIResponses(model: model, context: context, options: providerOptions)
    }
}

public func completeSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try streamSimple(model: model, context: context, options: options)
    return await stream.result()
}

private func mapAnthropicOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> AnthropicOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)

    if options?.reasoning == nil {
        return AnthropicOptions(
            temperature: options?.temperature,
            maxTokens: maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            thinkingEnabled: false
        )
    }

    let budgets: [ReasoningEffort: Int] = [
        .minimal: 1024,
        .low: 2048,
        .medium: 8192,
        .high: 16384,
        .xhigh: 16384,
    ]

    let effort = options?.reasoning ?? .medium
    return AnthropicOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        thinkingEnabled: true,
        thinkingBudgetTokens: budgets[effort] ?? 1024
    )
}

private func clampReasoningEffort(_ effort: ReasoningEffort?) -> ReasoningEffort? {
    guard let effort else { return nil }
    if effort == .xhigh {
        return .high
    }
    return effort
}

private func mapOpenAICompletionsOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAICompletionsOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampReasoningEffort(options?.reasoning)
    return OpenAICompletionsOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        reasoningEffort: reasoningEffort
    )
}

private func mapOpenAIResponsesOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAIResponsesOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampReasoningEffort(options?.reasoning)
    return OpenAIResponsesOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        reasoningEffort: reasoningEffort
    )
}

public enum StreamError: Error, LocalizedError {
    case missingApiKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for provider: \(provider)"
        }
    }
}
