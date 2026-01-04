import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent

public func runPrintMode(
    _ session: AgentSession,
    _ mode: Mode,
    _ messages: [String],
    _ initialMessage: String? = nil,
    _ initialImages: [ImageContent]? = nil
) async throws {
    let outputJson = mode == .json

    _ = session.subscribe { event in
        guard outputJson else { return }
        let payload = encodeSessionEvent(event)
        writeJsonLine(payload)
    }

    if let hookRunner = session.hookRunner {
        hookRunner.initialize(
            getModel: { [weak session] in session?.agent.state.model },
            sendMessageHandler: { [weak session] message, options in
                Task {
                    await session?.sendHookMessage(message, options: options)
                }
            },
            appendEntryHandler: { [weak session] customType, data in
                session?.sessionManager.appendCustomEntry(customType, data)
            },
            isIdle: { [weak session] in
                !(session?.isStreaming ?? true)
            },
            waitForIdle: { [weak session] in
                await session?.agent.waitForIdle()
            },
            abort: { [weak session] in
                guard let session else { return }
                Task { [session] in
                    await session.abort()
                }
            },
            hasPendingMessages: { [weak session] in
                (session?.pendingMessageCount ?? 0) > 0
            },
            hasUI: false
        )

        _ = hookRunner.onError { error in
            fputs("Hook error (\(error.hookPath)): \(error.error)\n", stderr)
        }

        _ = await hookRunner.emit(SessionStartEvent())
    }

    await session.emitCustomToolSessionEvent(.start, previousSessionFile: nil)

    if let initialMessage {
        try await session.prompt(initialMessage, options: PromptOptions(expandSlashCommands: nil, images: initialImages))
    }

    for message in messages {
        try await session.prompt(message)
    }

    if mode == .text {
        let lastMessage = session.agent.state.messages.last
        if case .assistant(let assistant) = lastMessage {
            if assistant.stopReason == .error || assistant.stopReason == .aborted {
                let message = assistant.errorMessage ?? "Request \(assistant.stopReason.rawValue)"
                fputs("\(message)\n", stderr)
                Darwin.exit(1)
            }
            for block in assistant.content {
                if case .text(let text) = block {
                    print(text.text)
                }
            }
        }
    }
}

private func writeJsonLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    print(json)
}
