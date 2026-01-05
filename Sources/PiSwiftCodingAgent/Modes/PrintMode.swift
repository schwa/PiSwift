import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent
import MiniTui

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
            getActiveToolsHandler: { [weak session] in
                session?.getActiveToolNames() ?? []
            },
            getAllToolsHandler: { [weak session] in
                session?.getAllToolNames() ?? []
            },
            setActiveToolsHandler: { [weak session] toolNames in
                session?.setActiveToolsByName(toolNames)
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
            let textBlocks = assistant.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }
            let combined = textBlocks.joined(separator: "\n")
            if !combined.isEmpty {
                if shouldUseAnsiOutput() {
                    let terminal = ProcessTerminal()
                    let width = max(40, terminal.columns)
                    let rendered = await MainActor.run { () -> String in
                        let markdown = Markdown(combined, paddingX: 0, paddingY: 0, theme: getMarkdownTheme())
                        return markdown.render(width: width).joined(separator: "\n")
                    }
                    writeStdout(rendered + "\n")
                } else {
                    writeStdout(combined + "\n")
                }
            }
        }
    }

    flushStdout()
}

private func writeJsonLine(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
        return
    }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.synchronizeFile()
}

private func writeStdout(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

private func flushStdout() {
    fflush(stdout)
}

private func shouldUseAnsiOutput() -> Bool {
    isatty(STDOUT_FILENO) != 0
}
