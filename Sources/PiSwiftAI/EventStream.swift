import Foundation

public final class EventStream<Element: Sendable, Result: Sendable>: AsyncSequence, @unchecked Sendable {
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>
    private var continuation: AsyncStream<Element>.Continuation
    private var done = false
    private let isComplete: (Element) -> Bool
    private let extractResult: (Element) -> Result
    private var resultValue: Result?
    private var resultContinuation: CheckedContinuation<Result, Never>?

    public init(isComplete: @escaping (Element) -> Bool, extractResult: @escaping (Element) -> Result) {
        self.isComplete = isComplete
        self.extractResult = extractResult
        var capturedContinuation: AsyncStream<Element>.Continuation!
        self.stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    public func push(_ event: Element) {
        guard !done else { return }

        if isComplete(event) {
            let result = extractResult(event)
            resultValue = result
            if let continuation = resultContinuation {
                resultContinuation = nil
                continuation.resume(returning: result)
            }
        }

        _ = continuation.yield(event)
    }

    public func end(_ result: Result? = nil) {
        guard !done else { return }
        done = true

        if let result = result {
            resultValue = result
            if let continuation = resultContinuation {
                resultContinuation = nil
                continuation.resume(returning: result)
            }
        }

        continuation.finish()
    }

    public func result() async -> Result {
        if let existing = resultValue {
            return existing
        }

        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        stream.makeAsyncIterator()
    }
}

public final class AssistantMessageEventStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = AssistantMessageEvent
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let inner: EventStream<Element, AssistantMessage>

    public init() {
        self.inner = EventStream<Element, AssistantMessage>(
            isComplete: { event in
                switch event {
                case .done, .error:
                    return true
                default:
                    return false
                }
            },
            extractResult: { event in
                switch event {
                case .done(_, let message):
                    return message
                case .error(_, let error):
                    return error
                default:
                    return AssistantMessage(
                        content: [],
                        api: .openAICompletions,
                        provider: "unknown",
                        model: "unknown",
                        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                        stopReason: .error,
                        errorMessage: "Unexpected event type for final result"
                    )
                }
            }
        )
    }

    public func push(_ event: AssistantMessageEvent) {
        inner.push(event)
    }

    public func end(_ result: AssistantMessage? = nil) {
        if let result = result {
            inner.end(result)
        } else {
            inner.end(nil)
        }
    }

    public func result() async -> AssistantMessage {
        await inner.result()
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        inner.makeAsyncIterator()
    }
}
