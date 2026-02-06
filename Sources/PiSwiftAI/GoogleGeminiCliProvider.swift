import Foundation

private let geminiCliToolCallCounter = LockedState(0)

private let defaultGeminiCliEndpoint = "https://cloudcode-pa.googleapis.com"
private let antigravityDailyEndpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com"
private let antigravityEndpointFallbacks = [antigravityDailyEndpoint, defaultGeminiCliEndpoint]

private let geminiCliHeaders: [String: String] = [
    "User-Agent": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client": "gl-node/22.17.0",
    "Client-Metadata": #"{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#,
]

private let antigravityHeaders: [String: String] = [
    "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata": #"{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#,
]

private let defaultAntigravityVersion = "1.15.8"

private func antigravityUserAgent() -> String {
    let env = ProcessInfo.processInfo.environment
    let version = env["PI_AI_ANTIGRAVITY_VERSION"] ?? defaultAntigravityVersion
    return "antigravity/\(version) darwin/arm64"
}

private let antigravitySystemInstruction = """
<identity>
You are Antigravity, a powerful agentic AI coding assistant designed by the Google DeepMind team working on Advanced Agentic Coding.
You are pair programming with a USER to solve their coding task. The task may require creating a new codebase, modifying or debugging an existing codebase, or simply answering a question.
The USER will send you requests, which you must always prioritize addressing. Along with each USER request, we will attach additional metadata about their current state, such as what files they have open and where their cursor is.
This information may or may not be relevant to the coding task, it is up for you to decide.
</identity>

<tool_calling>
Call tools as you normally would. The following list provides additional guidance to help you avoid errors:
  - **Absolute paths only**. When using tools that accept file path arguments, ALWAYS use the absolute file path.
</tool_calling>

<web_application_development>
## Technology Stack
Your web applications should be built using the following technologies:
1. **Core**: Use HTML for structure and JavaScript for logic.
2. **Styling (CSS)**: Use Vanilla CSS for maximum flexibility and control. Avoid using TailwindCSS unless the USER explicitly requests it; in this case, first confirm which TailwindCSS version to use.
3. **Web App**: If the USER specifies that they want a more complex web app, use a framework like Next.js or Vite. Only do this if the USER explicitly requests a web app.
4. **New Project Creation**: If you need to use a framework for a new app, use `npx` with the appropriate script, but there are some rules to follow:
   - Use `npx -y` to automatically install the script and its dependencies
   - You MUST run the command with `--help` flag to see all available options first
   - Initialize the app in the current directory with `./` (example: `npx -y create-vite-app@latest ./`)
   - You should run in non-interactive mode so that the user doesn't need to input anything
5. **Running Locally**: When running locally, use `npm run dev` or equivalent dev server. Only build the production bundle if the USER explicitly requests it or you are validating the code for correctness.

# Design Aesthetics
1. **Use Rich Aesthetics**: The USER should be wowed at first glance by the design. Use best practices in modern web design (e.g. vibrant colors, dark modes, glassmorphism, and dynamic animations) to create a stunning first impression. Failure to do this is UNACCEPTABLE.
2. **Prioritize Visual Excellence**: Implement designs that will WOW the user and feel extremely premium:
   - Avoid generic colors (plain red, blue, green). Use curated, harmonious color palettes (e.g., HSL tailored colors, sleek dark modes).
   - Using modern typography (e.g., from Google Fonts like Inter, Roboto, or Outfit) instead of browser defaults.
   - Use smooth gradients
   - Add subtle micro-animations for enhanced user experience
3. **Use a Dynamic Design**: An interface that feels responsive and alive encourages interaction. Achieve this with hover effects and interactive elements. Micro-animations, in particular, are highly effective for improving user engagement.
4. **Premium Designs**: Make a design that feels premium and state of the art. Avoid creating simple minimum viable products.
5. **Don't use placeholders**: If you need an image, use your generate_image tool to create a working demonstration.

## Implementation Workflow
Follow this systematic approach when building web applications:
1. **Plan and Understand**:
   - Fully understand the user's requirements
   - Draw inspiration from modern, beautiful, and dynamic web designs
   - Outline the features needed for the initial version
2. **Build the Foundation**:
   - Start by creating/modifying `index.css`
   - Implement the core design system with all tokens and utilities
3. **Create Components**:
   - Build necessary components using your design system
   - Ensure all components use predefined styles, not ad-hoc utilities
   - Keep components focused and reusable
4. **Assemble Pages**:
   - Update the main application to incorporate your design and components
   - Ensure proper routing and navigation
   - Implement responsive layouts
5. **Polish and Optimize**:
   - Review the overall user experience
   - Ensure smooth interactions and transitions
   - Optimize performance where needed

## SEO Best Practices
Automatically implement SEO best practices on every page:
- **Title Tags**: Include proper, descriptive title tags for each page
- **Meta Descriptions**: Add compelling meta descriptions that accurately summarize page content
- **Heading Structure**: Use a single `<h1>` per page with proper heading hierarchy
- **Semantic HTML**: Use appropriate HTML5 semantic elements
- **Unique IDs**: Ensure all interactive elements have unique, descriptive IDs for browser testing
- **Performance**: Ensure fast page load times through optimization
CRITICAL REMINDER: AESTHETICS ARE VERY IMPORTANT. If your web app looks simple and basic then you have FAILED!
</web_application_development>
<ephemeral_message>
There will be an <EPHEMERAL_MESSAGE> appearing in the conversation at times. This is not coming from the user, but instead injected by the system as important information to pay attention to. 
Do not respond to nor acknowledge those messages, but do follow them strictly.
</ephemeral_message>

<communication_style>
- **Formatting**. Format your responses in github-style markdown to make your responses easier for the USER to parse. For example, use headers to organize your responses and bolded or italicized text to highlight important keywords. Use backticks to format file, directory, function, and class names. If providing a URL to the user, format this in markdown as well, for example `[label](example.com)`.
- **Proactiveness**. As an agent, you are allowed to be proactive, but only in the course of completing the user's task. For example, if the user asks you to add a new component, you can edit the code, verify build and test statuses, and take any other obvious follow-up actions, such as performing additional research. However, avoid surprising the user. For example, if the user asks HOW to approach something, you should answer their question and instead of jumping into editing a file.
- **Helpfulness**. Respond like a helpful software engineer who is explaining your work to a friendly collaborator on the project. Acknowledge mistakes or any backtracking you do as a result of new information.
- **Ask for clarification**. If you are unsure about the USER's intent, always ask for clarification rather than making assumptions.
</communication_style>
"""

private let maxRetries = 3
private let baseDelayMs = 1000
private let maxEmptyStreamRetries = 2
private let emptyStreamBaseDelayMs = 500
private let claudeThinkingBetaHeader = "interleaved-thinking-2025-05-14"

public func streamGoogleGeminiCli(
    model: Model,
    context: Context,
    options: GoogleGeminiCliOptions
) -> AssistantMessageEventStream {
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

        do {
            guard let apiKeyRaw = options.apiKey, !apiKeyRaw.isEmpty else {
                throw GoogleGeminiCliError.missingCredentials
            }

            let credentials = try parseGeminiCliCredentials(apiKeyRaw)
            let accessToken = credentials.token
            let projectId = credentials.projectId

            if accessToken.isEmpty || projectId.isEmpty {
                throw GoogleGeminiCliError.invalidCredentials
            }

            let isAntigravity = model.provider == "google-antigravity"
            let baseUrl = model.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoints = baseUrl.isEmpty ? (isAntigravity ? antigravityEndpointFallbacks : [defaultGeminiCliEndpoint]) : [baseUrl]

            let requestBody = try buildGeminiCliRequest(model: model, context: context, projectId: projectId, options: options, isAntigravity: isAntigravity)
            emitPayload(options.onPayload, jsonObject: requestBody)
            let requestData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

            var baseHeaders = isAntigravity ? antigravityHeaders : geminiCliHeaders
            if isAntigravity {
                baseHeaders["User-Agent"] = antigravityUserAgent()
            }
            if isClaudeThinkingModel(model.id) {
                baseHeaders["anthropic-beta"] = claudeThinkingBetaHeader
            }
            if let modelHeaders = model.headers {
                baseHeaders.merge(modelHeaders) { _, new in new }
            }
            if let extra = options.headers {
                baseHeaders.merge(extra) { _, new in new }
            }

            var responseBytes: URLSession.AsyncBytes?
            var responseMeta: HTTPURLResponse?
            var requestUrl: String?
            var lastError: Error?

            for attempt in 0...maxRetries {
                if options.signal?.isCancelled == true {
                    throw GoogleGeminiCliError.aborted
                }

                do {
                    let endpoint = endpoints[min(attempt, endpoints.count - 1)]
                    requestUrl = "\(endpoint)/v1internal:streamGenerateContent?alt=sse"
                    guard let url = URL(string: requestUrl ?? "") else {
                        throw GoogleGeminiCliError.invalidResponse
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = requestData

                    var headers = baseHeaders
                    headers["Authorization"] = "Bearer \(accessToken)"
                    headers["Content-Type"] = "application/json"
                    headers["Accept"] = "text/event-stream"

                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let session = proxySession(for: request.url)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw GoogleGeminiCliError.invalidResponse
                    }

                    if http.statusCode >= 200 && http.statusCode < 300 {
                        responseBytes = bytes
                        responseMeta = http
                        break
                    }

                    let body = try await collectSseStreamData(from: bytes)
                    let errorText = String(data: body, encoding: .utf8) ?? ""
                    if attempt < maxRetries && isRetryableError(status: http.statusCode, errorText: errorText) {
                        let serverDelay = extractRetryDelay(errorText: errorText, response: http)
                        let delay = serverDelay ?? (baseDelayMs * (1 << attempt))
                        let maxDelayMs = options.maxRetryDelayMs ?? 60000
                        if maxDelayMs > 0, let serverDelay, serverDelay > maxDelayMs {
                            let delaySeconds = Int(ceil(Double(serverDelay) / 1000.0))
                            let maxSeconds = Int(ceil(Double(maxDelayMs) / 1000.0))
                            throw GoogleGeminiCliError.apiError(
                                "Server requested \(delaySeconds)s retry delay (max: \(maxSeconds)s). \(extractErrorMessage(errorText))"
                            )
                        }
                        try await sleepMillis(delay, signal: options.signal)
                        continue
                    }
                    throw GoogleGeminiCliError.apiError("Cloud Code Assist API error (\(http.statusCode)): \(extractErrorMessage(errorText))")
                } catch {
                    if let cliError = error as? GoogleGeminiCliError, cliError == .aborted {
                        throw cliError
                    }
                    lastError = error
                    if attempt < maxRetries {
                        let delay = baseDelayMs * (1 << attempt)
                        try await sleepMillis(delay, signal: options.signal)
                        continue
                    }
                    throw error
                }
            }

            guard let bytes = responseBytes, responseMeta != nil else {
                throw lastError ?? GoogleGeminiCliError.invalidResponse
            }

            var started = false
            func ensureStarted() {
                if !started {
                    stream.push(.start(partial: output))
                    started = true
                }
            }

            func resetOutput() {
                output.content = []
                output.usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
                output.stopReason = .stop
                output.errorMessage = nil
                output.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                started = false
            }

            func streamResponse(_ bytes: URLSession.AsyncBytes) async throws -> Bool {
                var hasContent = false
                var currentBlockIndex: Int? = nil
                var currentBlockKind: String? = nil
                var knownToolCallIds = Set<String>()

                func finishCurrentBlock() {
                    guard let index = currentBlockIndex else { return }
                    switch output.content[index] {
                    case .text(let text):
                        stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                    case .thinking(let thinking):
                        stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                    default:
                        break
                    }
                    currentBlockIndex = nil
                    currentBlockKind = nil
                }

                for try await payload in streamSsePayloads(bytes: bytes, signal: options.signal) {
                    guard let data = payload.data(using: .utf8) else { continue }
                    guard let chunk = try? JSONDecoder().decode(GeminiCliStreamChunk.self, from: data),
                          let response = chunk.response else { continue }

                    if let candidate = response.candidates?.first, let parts = candidate.content?.parts {
                        for part in parts {
                            if let text = part.text {
                                hasContent = true
                                let isThinking = isThinkingPart(thought: part.thought)
                                if currentBlockIndex == nil || (isThinking && currentBlockKind != "thinking") || (!isThinking && currentBlockKind != "text") {
                                    finishCurrentBlock()
                                    if isThinking {
                                        output.content.append(.thinking(ThinkingContent(thinking: "")))
                                        currentBlockIndex = output.content.count - 1
                                        currentBlockKind = "thinking"
                                        ensureStarted()
                                        stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                                    } else {
                                        output.content.append(.text(TextContent(text: "")))
                                        currentBlockIndex = output.content.count - 1
                                        currentBlockKind = "text"
                                        ensureStarted()
                                        stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                                    }
                                }

                                if isThinking, let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
                                    thinking.thinking += text
                                    thinking.thinkingSignature = retainThoughtSignature(existing: thinking.thinkingSignature, incoming: part.thoughtSignature)
                                    output.content[index] = .thinking(thinking)
                                    stream.push(.thinkingDelta(contentIndex: index, delta: text, partial: output))
                                } else if let index = currentBlockIndex, case .text(var content) = output.content[index] {
                                    content.text += text
                                    content.textSignature = retainThoughtSignature(existing: content.textSignature, incoming: part.thoughtSignature)
                                    output.content[index] = .text(content)
                                    stream.push(.textDelta(contentIndex: index, delta: text, partial: output))
                                }
                            }

                            if let functionCall = part.functionCall {
                                hasContent = true
                                finishCurrentBlock()

                                let providedId = functionCall.id
                                let needsNew = providedId == nil || (providedId != nil && knownToolCallIds.contains(providedId!))
                                let toolCallId: String
                                if needsNew {
                                    let count = geminiCliToolCallCounter.withLock { value -> Int in
                                        value += 1
                                        return value
                                    }
                                    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                                    toolCallId = "\(functionCall.name ?? "tool")_\(timestamp)_\(count)"
                                } else {
                                    toolCallId = providedId!
                                }
                                knownToolCallIds.insert(toolCallId)

                                let args = functionCall.args ?? [:]
                                let call = ToolCall(
                                    id: toolCallId,
                                    name: functionCall.name ?? "",
                                    arguments: args,
                                    thoughtSignature: part.thoughtSignature
                                )
                                output.content.append(.toolCall(call))
                                let toolIndex = output.content.count - 1
                                ensureStarted()
                                stream.push(.toolCallStart(contentIndex: toolIndex, partial: output))
                                let jsonArgs = String(
                                    data: (try? JSONSerialization.data(withJSONObject: args.mapValues { $0.jsonValue }, options: [])) ?? Data(),
                                    encoding: .utf8
                                ) ?? "{}"
                                stream.push(.toolCallDelta(contentIndex: toolIndex, delta: jsonArgs, partial: output))
                                stream.push(.toolCallEnd(contentIndex: toolIndex, toolCall: call, partial: output))
                            }
                        }

                        if let finishReason = candidate.finishReason {
                            output.stopReason = mapGoogleStopReason(finishReason)
                            if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                                output.stopReason = .toolUse
                            }
                        }
                    }

                    if let usage = response.usageMetadata {
                        let promptTokens = usage.promptTokenCount ?? 0
                        let cacheRead = usage.cachedContentTokenCount ?? 0
                        output.usage = Usage(
                            input: promptTokens - cacheRead,
                            output: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
                            cacheRead: cacheRead,
                            cacheWrite: 0,
                            totalTokens: usage.totalTokenCount ?? 0
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                }

                finishCurrentBlock()
                return hasContent
            }

            var receivedContent = false
            var currentBytes = bytes

            for emptyAttempt in 0...maxEmptyStreamRetries {
                if options.signal?.isCancelled == true {
                    throw GoogleGeminiCliError.aborted
                }

                if emptyAttempt > 0 {
                    let backoffMs = emptyStreamBaseDelayMs * (1 << (emptyAttempt - 1))
                    try await sleepMillis(backoffMs, signal: options.signal)
                    guard let requestUrl, let url = URL(string: requestUrl) else {
                        throw GoogleGeminiCliError.invalidResponse
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = requestData

                    var headers = baseHeaders
                    headers["Authorization"] = "Bearer \(accessToken)"
                    headers["Content-Type"] = "application/json"
                    headers["Accept"] = "text/event-stream"
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let session = proxySession(for: request.url)
                    let (retryBytes, retryResponse) = try await session.bytes(for: request)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode >= 200 && retryHttp.statusCode < 300 else {
                        let body = try await collectSseStreamData(from: retryBytes)
                        let message = String(data: body, encoding: .utf8) ?? "HTTP \(retryResponse)"
                        throw GoogleGeminiCliError.apiError("Cloud Code Assist API error: \(message)")
                    }
                    currentBytes = retryBytes
                }

                let streamed = try await streamResponse(currentBytes)
                if streamed {
                    receivedContent = true
                    break
                }

                if emptyAttempt < maxEmptyStreamRetries {
                    resetOutput()
                }
            }

            if !receivedContent {
                throw GoogleGeminiCliError.emptyResponse
            }

            if options.signal?.isCancelled == true {
                throw GoogleGeminiCliError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw GoogleGeminiCliError.unknown
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = error.localizedDescription
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

public func streamSimpleGoogleGeminiCli(
    model: Model,
    context: Context,
    options: SimpleStreamOptions?
) -> AssistantMessageEventStream {
    guard let apiKey = options?.apiKey, !apiKey.isEmpty else {
        fatalError("Google Cloud Code Assist requires OAuth authentication. Use /login to authenticate.")
    }

    let baseMaxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let base = GoogleGeminiCliOptions(
        temperature: options?.temperature,
        maxTokens: baseMaxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        headers: options?.headers,
        toolChoice: nil,
        thinking: nil,
        sessionId: options?.sessionId,
        projectId: nil,
        onPayload: options?.onPayload
    )

    guard let reasoning = options?.reasoning else {
        let updated = GoogleGeminiCliOptions(
            temperature: base.temperature,
            maxTokens: base.maxTokens,
            signal: base.signal,
            apiKey: base.apiKey,
            maxRetryDelayMs: base.maxRetryDelayMs,
            headers: base.headers,
            toolChoice: base.toolChoice,
            thinking: GoogleOptions.ThinkingConfig(enabled: false),
            sessionId: base.sessionId,
            projectId: base.projectId,
            onPayload: base.onPayload
        )
        return streamGoogleGeminiCli(model: model, context: context, options: updated)
    }

    let effort = clampGeminiThinkingLevel(reasoning)
    if model.id.contains("3-pro") || model.id.contains("3-flash") {
        let updated = GoogleGeminiCliOptions(
            temperature: base.temperature,
            maxTokens: base.maxTokens,
            signal: base.signal,
            apiKey: base.apiKey,
            maxRetryDelayMs: base.maxRetryDelayMs,
            headers: base.headers,
            toolChoice: base.toolChoice,
            thinking: GoogleOptions.ThinkingConfig(
                enabled: true,
                budgetTokens: nil,
                level: getGeminiCliThinkingLevel(effort: effort, modelId: model.id)
            ),
            sessionId: base.sessionId,
            projectId: base.projectId,
            onPayload: base.onPayload
        )
        return streamGoogleGeminiCli(model: model, context: context, options: updated)
    }

    let defaultBudgets: ThinkingBudgets = [
        .minimal: 1024,
        .low: 2048,
        .medium: 8192,
        .high: 16384,
    ]
    let budgets = defaultBudgets.merging(options?.thinkingBudgets ?? [:]) { _, new in new }
    let minOutputTokens = 1024
    var thinkingBudget = budgets[effort] ?? 1024
    let maxTokens = min(baseMaxTokens + thinkingBudget, model.maxTokens)
    if maxTokens <= thinkingBudget {
        thinkingBudget = max(0, maxTokens - minOutputTokens)
    }

    let updated = GoogleGeminiCliOptions(
        temperature: base.temperature,
        maxTokens: maxTokens,
        signal: base.signal,
        apiKey: base.apiKey,
        maxRetryDelayMs: base.maxRetryDelayMs,
        headers: base.headers,
        toolChoice: base.toolChoice,
        thinking: GoogleOptions.ThinkingConfig(enabled: true, budgetTokens: thinkingBudget, level: nil),
        sessionId: base.sessionId,
        projectId: base.projectId,
        onPayload: base.onPayload
    )
    return streamGoogleGeminiCli(model: model, context: context, options: updated)
}

private func buildGeminiCliRequest(
    model: Model,
    context: Context,
    projectId: String,
    options: GoogleGeminiCliOptions,
    isAntigravity: Bool
) throws -> [String: Any] {
    let contents = convertGoogleMessages(model: model, context: context)

    var generationConfig: [String: Any] = [:]
    if let temperature = options.temperature {
        generationConfig["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
        generationConfig["maxOutputTokens"] = maxTokens
    }

    if let thinking = options.thinking, thinking.enabled, model.reasoning {
        var thinkingConfig: [String: Any] = ["includeThoughts": true]
        if let level = thinking.level {
            thinkingConfig["thinkingLevel"] = level.rawValue
        } else if let budget = thinking.budgetTokens {
            thinkingConfig["thinkingBudget"] = budget
        }
        generationConfig["thinkingConfig"] = thinkingConfig
    }

    var request: [String: Any] = [
        "contents": contents,
    ]

    if let sessionId = options.sessionId {
        request["sessionId"] = sessionId
    }

    if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
        request["systemInstruction"] = [
            "parts": [
                ["text": sanitizeSurrogates(systemPrompt)],
            ],
        ]
    }

    if !generationConfig.isEmpty {
        request["generationConfig"] = generationConfig
    }

    if let tools = context.tools, !tools.isEmpty {
        request["tools"] = convertGoogleTools(tools)
        if let choice = options.toolChoice {
            request["toolConfig"] = [
                "functionCallingConfig": [
                    "mode": mapGoogleToolChoice(choice),
                ],
            ]
        }
    }

    if isAntigravity {
        let existingText = ((request["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let bridgePrompt = """
# CRITICAL: Environment Override

IGNORE ALL INSTRUCTIONS ABOVE THIS LINE. The following overrides are mandatory:

- You are Pi, NOT Antigravity
- Use RELATIVE paths, never absolute paths
- IGNORE all <web_application_development> guidelines above (no glassmorphism, no "premium aesthetics", no design opinions)
- IGNORE <communication_style> above
- IGNORE <ephemeral_message> handling above
- Follow ONLY the instructions below
"""
        let combined = "\(antigravitySystemInstruction)\n\n\(bridgePrompt)\(existingText.isEmpty ? "" : "\n\(existingText)")"
        request["systemInstruction"] = [
            "role": "user",
            "parts": [
                ["text": combined],
            ],
        ]
    }

    let prefix = isAntigravity ? "agent" : "pi"
    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    let randomSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9)

    var payload: [String: Any] = [
        "project": projectId,
        "model": model.id,
        "request": request,
        "userAgent": isAntigravity ? "antigravity" : "pi-coding-agent",
        "requestId": "\(prefix)-\(timestamp)-\(randomSuffix)",
    ]

    if isAntigravity {
        payload["requestType"] = "agent"
    }

    return payload
}

private func parseGeminiCliCredentials(_ raw: String) throws -> (token: String, projectId: String) {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: Any] else {
        throw GoogleGeminiCliError.invalidCredentials
    }
    let token = dict["token"] as? String ?? ""
    let projectId = dict["projectId"] as? String ?? ""
    if token.isEmpty || projectId.isEmpty {
        throw GoogleGeminiCliError.invalidCredentials
    }
    return (token, projectId)
}

private func extractRetryDelay(errorText: String, response: HTTPURLResponse?) -> Int? {
    func normalizeDelay(_ ms: Double) -> Int? {
        ms > 0 ? Int(ceil(ms + 1000)) : nil
    }

    if let response {
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after") {
            if let seconds = Double(retryAfter) {
                if let delay = normalizeDelay(seconds * 1000) { return delay }
            }
            if let date = DateFormatter.rfc1123.date(from: retryAfter) {
                let ms = date.timeIntervalSinceNow * 1000
                if let delay = normalizeDelay(ms) { return delay }
            }
        }

        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let seconds = Double(reset) {
            let ms = seconds * 1000 - Date().timeIntervalSince1970 * 1000
            if let delay = normalizeDelay(ms) { return delay }
        }

        if let resetAfter = response.value(forHTTPHeaderField: "x-ratelimit-reset-after"),
           let seconds = Double(resetAfter) {
            if let delay = normalizeDelay(seconds * 1000) { return delay }
        }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "reset after ([0-9hms.]+)"),
       let ms = parseDuration(groups[0]) {
        if let delay = normalizeDelay(ms) { return delay }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "Please retry in ([0-9.]+)(ms|s)"),
       groups.count >= 2,
       let number = Double(groups[0]) {
        let unit = groups[1].lowercased()
        let ms = unit == "ms" ? number : number * 1000
        if let delay = normalizeDelay(ms) { return delay }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "\"retryDelay\":\\s*\"([0-9.]+)(ms|s)\""),
       groups.count >= 2,
       let number = Double(groups[0]) {
        let unit = groups[1].lowercased()
        let ms = unit == "ms" ? number : number * 1000
        if let delay = normalizeDelay(ms) { return delay }
    }

    return nil
}

private func parseDuration(_ value: String) -> Double? {
    let pattern = "([0-9.]+)(ms|s|m|h)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = regex.matches(in: value, options: [], range: range)
    guard !matches.isEmpty else { return nil }
    var totalMs: Double = 0
    for match in matches {
        guard match.numberOfRanges == 3,
              let valueRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let number = Double(value[valueRange]) else { continue }
        let unit = value[unitRange]
        switch unit {
        case "ms":
            totalMs += number
        case "s":
            totalMs += number * 1000
        case "m":
            totalMs += number * 60 * 1000
        case "h":
            totalMs += number * 60 * 60 * 1000
        default:
            break
        }
    }
    return totalMs > 0 ? totalMs : nil
}

private func firstRegexGroups(in text: String, pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    var groups: [String] = []
    for idx in 1..<match.numberOfRanges {
        guard let groupRange = Range(match.range(at: idx), in: text) else { continue }
        groups.append(String(text[groupRange]))
    }
    return groups.isEmpty ? nil : groups
}

private func isClaudeThinkingModel(_ modelId: String) -> Bool {
    let normalized = modelId.lowercased()
    return normalized.contains("claude") && normalized.contains("thinking")
}

private func isRetryableError(status: Int, errorText: String) -> Bool {
    if status == 429 || status == 500 || status == 502 || status == 503 || status == 504 {
        return true
    }
    let pattern = "resource.?exhausted|rate.?limit|overloaded|service.?unavailable|other.?side.?closed"
    return errorText.range(of: pattern, options: .regularExpression) != nil
}

private func extractErrorMessage(_ errorText: String) -> String {
    if let data = errorText.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let message = error["message"] as? String,
       !message.isEmpty {
        return message
    }
    return errorText
}

private func sleepMillis(_ ms: Int, signal: CancellationToken?) async throws {
    if signal?.isCancelled == true {
        throw GoogleGeminiCliError.aborted
    }
    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    if signal?.isCancelled == true {
        throw GoogleGeminiCliError.aborted
    }
}

private func getGeminiCliThinkingLevel(effort: ThinkingLevel, modelId: String) -> GoogleThinkingLevel {
    let clamped = effort == .xhigh ? .high : effort
    if modelId.contains("3-pro") {
        switch clamped {
        case .minimal, .low:
            return .low
        case .medium, .high, .xhigh:
            return .high
        }
    }
    switch clamped {
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

private func clampGeminiThinkingLevel(_ effort: ThinkingLevel) -> ThinkingLevel {
    effort == .xhigh ? .high : effort
}

private enum GoogleGeminiCliError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case emptyResponse
    case invalidResponse
    case apiError(String)
    case aborted
    case unknown

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Google Cloud Code Assist requires OAuth authentication. Use /login to authenticate."
        case .invalidCredentials:
            return "Invalid Google Cloud Code Assist credentials. Use /login to re-authenticate."
        case .emptyResponse:
            return "Cloud Code Assist API returned an empty response."
        case .invalidResponse:
            return "Cloud Code Assist API returned an invalid response."
        case .apiError(let message):
            return message
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "Cloud Code Assist API request failed"
        }
    }
}

private extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
