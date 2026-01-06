import Foundation

public enum Api: String, Sendable {
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
}

public enum KnownProvider: String, Sendable {
    case openai
    case anthropic
}

public typealias Provider = String

public enum ThinkingLevel: String, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public typealias ReasoningEffort = ThinkingLevel

public struct StreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?

    public init(temperature: Double? = nil, maxTokens: Int? = nil, signal: CancellationToken? = nil, apiKey: String? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
    }
}

public struct SimpleStreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var reasoning: ThinkingLevel?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        reasoning: ThinkingLevel? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.reasoning = reasoning
    }
}

public enum OpenAICompatMaxTokensField: String, Sendable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

public struct OpenAICompat: Sendable {
    public var supportsStore: Bool?
    public var supportsDeveloperRole: Bool?
    public var supportsReasoningEffort: Bool?
    public var maxTokensField: OpenAICompatMaxTokensField?
    public var requiresToolResultName: Bool?
    public var requiresAssistantAfterToolResult: Bool?
    public var requiresThinkingAsText: Bool?
    public var requiresMistralToolIds: Bool?

    public init(
        supportsStore: Bool? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsReasoningEffort: Bool? = nil,
        maxTokensField: OpenAICompatMaxTokensField? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        requiresThinkingAsText: Bool? = nil,
        requiresMistralToolIds: Bool? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.maxTokensField = maxTokensField
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresMistralToolIds = requiresMistralToolIds
    }
}

public struct ModelCost: Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public enum ModelInput: String, Sendable {
    case text
    case image
}

public struct Model: Sendable {
    public let id: String
    public let name: String
    public let api: Api
    public let provider: Provider
    public let baseUrl: String
    public let reasoning: Bool
    public let input: [ModelInput]
    public let cost: ModelCost
    public let contextWindow: Int
    public let maxTokens: Int
    public let headers: [String: String]?
    public let compat: OpenAICompat?

    public init(
        id: String,
        name: String,
        api: Api,
        provider: Provider,
        baseUrl: String,
        reasoning: Bool,
        input: [ModelInput],
        cost: ModelCost,
        contextWindow: Int,
        maxTokens: Int,
        headers: [String: String]? = nil,
        compat: OpenAICompat? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseUrl = baseUrl
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
        self.compat = compat
    }
}

public struct UsageCost: Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }
}

public struct Usage: Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var totalTokens: Int
    public var cost: UsageCost

    public init(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        totalTokens: Int,
        cost: UsageCost = UsageCost()
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

public enum StopReason: String, Sendable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

public struct TextContent: Sendable {
    public let type: String = "text"
    public var text: String
    public var textSignature: String?

    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

public struct ThinkingContent: Sendable {
    public let type: String = "thinking"
    public var thinking: String
    public var thinkingSignature: String?

    public init(thinking: String, thinkingSignature: String? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
    }
}

public struct ImageContent: Sendable {
    public let type: String = "image"
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Sendable {
    public let type: String = "toolCall"
    public var id: String
    public var name: String
    public var arguments: [String: AnyCodable]
    public var thoughtSignature: String?

    public init(id: String, name: String, arguments: [String: AnyCodable], thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

public enum ContentBlock: Sendable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case image(ImageContent)
    case toolCall(ToolCall)
}

public struct UserMessage: Sendable {
    public let role: String = "user"
    public var content: UserContent
    public var timestamp: Int64

    public init(content: UserContent, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.content = content
        self.timestamp = timestamp
    }
}

public enum UserContent: Sendable {
    case text(String)
    case blocks([ContentBlock])
}

public struct AssistantMessage: Sendable {
    public let role: String = "assistant"
    public var content: [ContentBlock]
    public var api: Api
    public var provider: Provider
    public var model: String
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Int64

    public init(
        content: [ContentBlock],
        api: Api,
        provider: Provider,
        model: String,
        usage: Usage,
        stopReason: StopReason,
        errorMessage: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public struct ToolResultMessage: Sendable {
    public let role: String = "toolResult"
    public var toolCallId: String
    public var toolName: String
    public var content: [ContentBlock]
    public var details: AnyCodable?
    public var isError: Bool
    public var timestamp: Int64

    public init(
        toolCallId: String,
        toolName: String,
        content: [ContentBlock],
        details: AnyCodable? = nil,
        isError: Bool,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
    }
}

public enum Message: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        }
    }
}

public struct AITool: Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]

    public init(name: String, description: String, parameters: [String: AnyCodable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [AITool]?

    public init(systemPrompt: String? = nil, messages: [Message], tools: [AITool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolCallStart(contentIndex: Int, partial: AssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    case error(reason: StopReason, error: AssistantMessage)
}

public enum OpenAIToolChoice: Sendable {
    case auto
    case none
    case required
    case function(String)
}

public struct OpenAICompletionsOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var toolChoice: OpenAIToolChoice?
    public var reasoningEffort: ThinkingLevel?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        toolChoice: OpenAIToolChoice? = nil,
        reasoningEffort: ThinkingLevel? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
    }
}

public enum OpenAIReasoningSummary: String, Sendable {
    case auto
    case detailed
    case concise
}

public struct OpenAIResponsesOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAIReasoningSummary?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
    }
}

public enum AnthropicToolChoice: Sendable {
    case auto
    case any
    case none
    case tool(name: String)
}

public struct AnthropicOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var thinkingEnabled: Bool?
    public var thinkingBudgetTokens: Int?
    public var interleavedThinking: Bool?
    public var toolChoice: AnthropicToolChoice?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        thinkingEnabled: Bool? = nil,
        thinkingBudgetTokens: Int? = nil,
        interleavedThinking: Bool? = nil,
        toolChoice: AnthropicToolChoice? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.interleavedThinking = interleavedThinking
        self.toolChoice = toolChoice
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}
