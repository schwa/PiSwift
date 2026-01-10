import Foundation

private func shouldLogApiKeyDebug() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_DEBUG_API_KEYS"] ?? env["PI_DEBUG_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

private func apiKeyInfo(_ key: String?) -> String {
    guard let key else { return "missing" }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasWhitespace = trimmed.count != key.count
    return "present length=\(key.count) trimmedLength=\(trimmed.count) whitespace=\(hasWhitespace)"
}

private func logApiKeyDebug(_ message: String) {
    guard shouldLogApiKeyDebug() else { return }
    let line = "PI_DEBUG: \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

public func getEnvApiKey(provider: KnownProvider) -> String? {
    getEnvApiKey(provider: provider.rawValue)
}

public func getEnvApiKey(provider: String) -> String? {
    let env = ProcessInfo.processInfo.environment

    if provider == "anthropic" {
        let oauth = env["ANTHROPIC_OAUTH_TOKEN"]
        let apiKey = env["ANTHROPIC_API_KEY"]
        let selected = oauth ?? apiKey
        let source: String
        if oauth != nil {
            source = "ANTHROPIC_OAUTH_TOKEN"
        } else if apiKey != nil {
            source = "ANTHROPIC_API_KEY"
        } else {
            source = "none"
        }
        logApiKeyDebug("provider=anthropic env apiKey=\(apiKeyInfo(apiKey)) oauth=\(apiKeyInfo(oauth)) selected=\(source)")
        return selected
    }

    if provider == "openai" {
        let apiKey = env["OPENAI_API_KEY"]
        logApiKeyDebug("provider=openai env apiKey=\(apiKeyInfo(apiKey))")
        return apiKey
    }

    if provider == "opencode" {
        let apiKey = env["OPENCODE_API_KEY"]
        logApiKeyDebug("provider=opencode env apiKey=\(apiKeyInfo(apiKey))")
        return apiKey
    }

    return nil
}

public func stream(model: Model, context: Context, options: StreamOptions? = nil) throws -> AssistantMessageEventStream {
    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        throw StreamError.missingApiKey(model.provider)
    }
    let source = options?.apiKey != nil ? "options" : "env"
    logApiKeyDebug("provider=\(model.provider) source=\(source) \(apiKeyInfo(apiKey))")

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
            apiKey: apiKey,
            sessionId: options?.sessionId
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
    let source = options?.apiKey != nil ? "options" : "env"
    logApiKeyDebug("provider=\(model.provider) source=\(source) \(apiKeyInfo(apiKey))")

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

    let defaultBudgets: ThinkingBudgets = [
        .minimal: 1024,
        .low: 2048,
        .medium: 8192,
        .high: 16384,
    ]
    let budgets = defaultBudgets.merging(options?.thinkingBudgets ?? [:]) { _, new in new }

    let minOutputTokens = 1024
    let effort = clampThinkingLevel(options?.reasoning) ?? .medium
    var thinkingBudget = budgets[effort] ?? 1024
    let cappedMaxTokens = min(maxTokens + thinkingBudget, model.maxTokens)
    if cappedMaxTokens <= thinkingBudget {
        thinkingBudget = max(0, cappedMaxTokens - minOutputTokens)
    }

    return AnthropicOptions(
        temperature: options?.temperature,
        maxTokens: cappedMaxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        thinkingEnabled: true,
        thinkingBudgetTokens: thinkingBudget
    )
}

private func clampThinkingLevel(_ effort: ThinkingLevel?) -> ThinkingLevel? {
    guard let effort else { return nil }
    if effort == .xhigh {
        return .high
    }
    return effort
}

private func mapOpenAICompletionsOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAICompletionsOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampThinkingLevel(options?.reasoning)
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
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampThinkingLevel(options?.reasoning)
    return OpenAIResponsesOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId
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
