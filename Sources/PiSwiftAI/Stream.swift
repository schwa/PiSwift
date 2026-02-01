import Foundation

public func createAssistantMessageEventStream() -> AssistantMessageEventStream {
    AssistantMessageEventStream()
}

public func resetApiProviders() {
    // No-op in Swift port (providers are static)
}

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

    if provider == "github-copilot" {
        return env["COPILOT_GITHUB_TOKEN"] ?? env["GH_TOKEN"] ?? env["GITHUB_TOKEN"]
    }

    if provider == "amazon-bedrock" {
        if env["AWS_PROFILE"] != nil ||
            (env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil) ||
            env["AWS_BEARER_TOKEN_BEDROCK"] != nil ||
            env["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] != nil ||
            env["AWS_CONTAINER_CREDENTIALS_FULL_URI"] != nil ||
            env["AWS_WEB_IDENTITY_TOKEN_FILE"] != nil {
            return "<authenticated>"
        }
    }

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

    let envMap: [String: String] = [
        "openai": "OPENAI_API_KEY",
        "openai-codex": "OPENAI_API_KEY",
        "azure-openai-responses": "AZURE_OPENAI_API_KEY",
        "google": "GEMINI_API_KEY",
        "groq": "GROQ_API_KEY",
        "cerebras": "CEREBRAS_API_KEY",
        "xai": "XAI_API_KEY",
        "openrouter": "OPENROUTER_API_KEY",
        "vercel-ai-gateway": "AI_GATEWAY_API_KEY",
        "zai": "ZAI_API_KEY",
        "mistral": "MISTRAL_API_KEY",
        "minimax": "MINIMAX_API_KEY",
        "minimax-cn": "MINIMAX_CN_API_KEY",
        "huggingface": "HF_TOKEN",
        "opencode": "OPENCODE_API_KEY",
        "kimi-coding": "KIMI_API_KEY",
    ]

    if provider == "google-vertex" {
        if hasGoogleVertexCredentials(env: env) {
            return "<authenticated>"
        }
    }

    if let envVar = envMap[provider] {
        let apiKey = env[envVar]
        logApiKeyDebug("provider=\(provider) env apiKey=\(apiKeyInfo(apiKey))")
        return apiKey
    }

    return nil
}

private func hasGoogleVertexCredentials(env: [String: String]) -> Bool {
    let project = env["GOOGLE_CLOUD_PROJECT"] ?? env["GCLOUD_PROJECT"]
    let location = env["GOOGLE_CLOUD_LOCATION"]
    guard project != nil, location != nil else { return false }

    let fileManager = FileManager.default
    if let gacPath = env["GOOGLE_APPLICATION_CREDENTIALS"],
       fileManager.fileExists(atPath: gacPath) {
        return true
    }

    let defaultPath = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/gcloud/application_default_credentials.json")
        .path
    return fileManager.fileExists(atPath: defaultPath)
}

public func stream(model: Model, context: Context, options: StreamOptions? = nil) throws -> AssistantMessageEventStream {
    if model.api == .bedrockConverseStream {
        let providerOptions = BedrockOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            headers: options?.headers
        )
        return streamBedrock(model: model, context: context, options: providerOptions)
    }

    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        throw StreamError.missingApiKey(model.provider)
    }
    let source = options?.apiKey != nil ? "options" : "env"
    logApiKeyDebug("provider=\(model.provider) source=\(source) \(apiKeyInfo(apiKey))")

    switch model.api {
    case .bedrockConverseStream:
        let providerOptions = BedrockOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            headers: options?.headers
        )
        return streamBedrock(model: model, context: context, options: providerOptions)
    case .openAICompletions:
        let providerOptions = OpenAICompletionsOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            headers: options?.headers
        )
        return streamOpenAICompletions(model: model, context: context, options: providerOptions)
    case .openAIResponses:
        let providerOptions = OpenAIResponsesOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            sessionId: options?.sessionId,
            headers: options?.headers
        )
        return streamOpenAIResponses(model: model, context: context, options: providerOptions)
    case .azureOpenAIResponses:
        let providerOptions = AzureOpenAIResponsesOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            sessionId: options?.sessionId,
            headers: options?.headers
        )
        return streamAzureOpenAIResponses(model: model, context: context, options: providerOptions)
    case .anthropicMessages:
        let providerOptions = AnthropicOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            headers: options?.headers
        )
        return streamAnthropic(model: model, context: context, options: providerOptions)
    case .googleGenerativeAI:
        let providerOptions = GoogleOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            headers: options?.headers
        )
        return streamGoogle(model: model, context: context, options: providerOptions)
    case .googleGeminiCli:
        let providerOptions = GoogleGeminiCliOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            headers: options?.headers,
            sessionId: options?.sessionId
        )
        return streamGoogleGeminiCli(model: model, context: context, options: providerOptions)
    case .googleVertex:
        let providerOptions = GoogleVertexOptions(
            temperature: options?.temperature,
            maxTokens: options?.maxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            headers: options?.headers
        )
        return streamGoogleVertex(model: model, context: context, options: providerOptions)
    }
}

public func complete(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try stream(model: model, context: context, options: options)
    return await stream.result()
}

public func streamSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) throws -> AssistantMessageEventStream {
    if model.api == .bedrockConverseStream {
        let providerOptions = mapBedrockOptions(model: model, options: options)
        return streamBedrock(model: model, context: context, options: providerOptions)
    }

    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        throw StreamError.missingApiKey(model.provider)
    }
    let source = options?.apiKey != nil ? "options" : "env"
    logApiKeyDebug("provider=\(model.provider) source=\(source) \(apiKeyInfo(apiKey))")

    switch model.api {
    case .bedrockConverseStream:
        let providerOptions = mapBedrockOptions(model: model, options: options)
        return streamBedrock(model: model, context: context, options: providerOptions)
    case .anthropicMessages:
        let providerOptions = mapAnthropicOptions(model: model, options: options, apiKey: apiKey)
        return streamAnthropic(model: model, context: context, options: providerOptions)
    case .openAICompletions:
        let providerOptions = mapOpenAICompletionsOptions(model: model, options: options, apiKey: apiKey)
        return streamOpenAICompletions(model: model, context: context, options: providerOptions)
    case .openAIResponses:
        let providerOptions = mapOpenAIResponsesOptions(model: model, options: options, apiKey: apiKey)
        return streamOpenAIResponses(model: model, context: context, options: providerOptions)
    case .azureOpenAIResponses:
        let providerOptions = mapAzureOpenAIResponsesOptions(model: model, options: options, apiKey: apiKey)
        return streamAzureOpenAIResponses(model: model, context: context, options: providerOptions)
    case .googleGenerativeAI:
        let providerOptions = mapGoogleOptions(model: model, options: options, apiKey: apiKey)
        return streamGoogle(model: model, context: context, options: providerOptions)
    case .googleGeminiCli:
        return streamSimpleGoogleGeminiCli(model: model, context: context, options: options)
    case .googleVertex:
        let providerOptions = mapGoogleVertexOptions(model: model, options: options, apiKey: apiKey)
        return streamGoogleVertex(model: model, context: context, options: providerOptions)
    }
}

public func completeSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try streamSimple(model: model, context: context, options: options)
    return await stream.result()
}

private func mapAnthropicOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> AnthropicOptions {
    let baseMaxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)

    if options?.reasoning == nil {
        return AnthropicOptions(
            temperature: options?.temperature,
            maxTokens: baseMaxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            thinkingEnabled: false,
            headers: options?.headers
        )
    }

    let effort = clampThinkingLevel(options?.reasoning) ?? .medium
    let adjusted = adjustMaxTokensForThinking(
        baseMaxTokens: baseMaxTokens,
        modelMaxTokens: model.maxTokens,
        reasoningLevel: effort,
        customBudgets: options?.thinkingBudgets
    )

    return AnthropicOptions(
        temperature: options?.temperature,
        maxTokens: adjusted.maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        thinkingEnabled: true,
        thinkingBudgetTokens: adjusted.thinkingBudget,
        headers: options?.headers
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
        reasoningEffort: reasoningEffort,
        headers: options?.headers
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
        sessionId: options?.sessionId,
        headers: options?.headers
    )
}

private func mapAzureOpenAIResponsesOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> AzureOpenAIResponsesOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampThinkingLevel(options?.reasoning)
    return AzureOpenAIResponsesOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId,
        headers: options?.headers
    )
}

private func mapGoogleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> GoogleOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let thinking = buildGoogleThinkingConfig(model: model, options: options)
    return GoogleOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        headers: options?.headers,
        thinking: thinking
    )
}

private func mapGoogleVertexOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> GoogleVertexOptions {
    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let thinking = buildGoogleThinkingConfig(model: model, options: options)
    return GoogleVertexOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        headers: options?.headers,
        thinking: thinking
    )
}

private func buildGoogleThinkingConfig(model: Model, options: SimpleStreamOptions?) -> GoogleOptions.ThinkingConfig? {
    guard model.reasoning else { return nil }
    guard let reasoning = options?.reasoning else { return nil }
    let clamped = supportsXhigh(model: model) ? reasoning : clampThinkingLevel(reasoning) ?? reasoning
    if model.id.contains("3-pro") || model.id.contains("3-flash") {
        return GoogleOptions.ThinkingConfig(
            enabled: true,
            budgetTokens: nil,
            level: googleThinkingLevel(for: clamped, modelId: model.id)
        )
    }
    let budget = googleThinkingBudget(modelId: model.id, effort: clamped, customBudgets: options?.thinkingBudgets)
    return GoogleOptions.ThinkingConfig(
        enabled: true,
        budgetTokens: budget,
        level: nil
    )
}

private func googleThinkingBudget(modelId: String, effort: ThinkingLevel, customBudgets: ThinkingBudgets?) -> Int {
    if let custom = customBudgets?[effort] {
        return custom
    }
    let clamped = clampThinkingLevel(effort) ?? effort
    if modelId.contains("2.5-pro") {
        let budgets: ThinkingBudgets = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 32768,
        ]
        return budgets[clamped] ?? -1
    }
    if modelId.contains("2.5-flash") {
        let budgets: ThinkingBudgets = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 24576,
        ]
        return budgets[clamped] ?? -1
    }
    return -1
}

private func mapBedrockOptions(model: Model, options: SimpleStreamOptions?) -> BedrockOptions {
    let baseMaxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoning = supportsXhigh(model: model) ? options?.reasoning : clampThinkingLevel(options?.reasoning)

    if let reasoning, (model.id.contains("anthropic.claude") || model.id.contains("anthropic/claude")) {
        let adjusted = adjustMaxTokensForThinking(
            baseMaxTokens: baseMaxTokens,
            modelMaxTokens: model.maxTokens,
            reasoningLevel: reasoning,
            customBudgets: options?.thinkingBudgets
        )
        return BedrockOptions(
            temperature: options?.temperature,
            maxTokens: adjusted.maxTokens,
            signal: options?.signal,
            reasoning: reasoning,
            thinkingBudgets: mergeThinkingBudgets(options?.thinkingBudgets, reasoning: reasoning, thinkingBudget: adjusted.thinkingBudget),
            headers: options?.headers
        )
    }

    return BedrockOptions(
        temperature: options?.temperature,
        maxTokens: baseMaxTokens,
        signal: options?.signal,
        reasoning: reasoning,
        thinkingBudgets: options?.thinkingBudgets,
        headers: options?.headers
    )
}

private func adjustMaxTokensForThinking(
    baseMaxTokens: Int,
    modelMaxTokens: Int,
    reasoningLevel: ThinkingLevel,
    customBudgets: ThinkingBudgets?
) -> (maxTokens: Int, thinkingBudget: Int) {
    let defaultBudgets: ThinkingBudgets = [
        .minimal: 1024,
        .low: 2048,
        .medium: 8192,
        .high: 16384,
    ]
    let budgets = defaultBudgets.merging(customBudgets ?? [:]) { _, new in new }
    let minOutputTokens = 1024
    let clamped = clampThinkingLevel(reasoningLevel) ?? reasoningLevel
    var thinkingBudget = budgets[clamped] ?? 1024
    let maxTokens = min(baseMaxTokens + thinkingBudget, modelMaxTokens)
    if maxTokens <= thinkingBudget {
        thinkingBudget = max(0, maxTokens - minOutputTokens)
    }
    return (maxTokens, thinkingBudget)
}

private func mergeThinkingBudgets(_ budgets: ThinkingBudgets?, reasoning: ThinkingLevel, thinkingBudget: Int) -> ThinkingBudgets? {
    var merged = budgets ?? [:]
    let clamped = clampThinkingLevel(reasoning) ?? reasoning
    merged[clamped] = thinkingBudget
    return merged
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
