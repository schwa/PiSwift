import Foundation
import MiniTui
import PiSwiftAI

public final class FooterComponent: Component {
    private let session: AgentSession
    private var autoCompactEnabled = true
    private var hookStatuses: [String: String] = [:]
    private var cachedBranch: String?
    private var branchCacheValid = false

    public init(session: AgentSession) {
        self.session = session
    }

    public func setAutoCompactEnabled(_ enabled: Bool) {
        autoCompactEnabled = enabled
    }

    public func setHookStatus(_ key: String, _ text: String?) {
        if let text {
            hookStatuses[key] = sanitizeStatusText(text)
        } else {
            hookStatuses.removeValue(forKey: key)
        }
    }

    public func invalidate() {
        branchCacheValid = false
    }

    public func render(width: Int) -> [String] {
        let state = session.agent.state

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0

        for entry in session.sessionManager.getEntries() {
            if case let .message(messageEntry) = entry,
               case let .assistant(message) = messageEntry.message {
                totalInput += message.usage.input
                totalOutput += message.usage.output
                totalCacheRead += message.usage.cacheRead
                totalCacheWrite += message.usage.cacheWrite
                totalCost += message.usage.cost.total
            }
        }

        let lastAssistant = state.messages.reversed().compactMap { message -> AssistantMessage? in
            if case let .assistant(assistant) = message, assistant.stopReason != .aborted {
                return assistant
            }
            return nil
        }.first

        let contextTokens = lastAssistant.map { $0.usage.input + $0.usage.output + $0.usage.cacheRead + $0.usage.cacheWrite } ?? 0
        let contextWindow = state.model.contextWindow
        let contextPercentValue = contextWindow > 0 ? (Double(contextTokens) / Double(contextWindow)) * 100.0 : 0.0
        let contextPercent = String(format: "%.1f", contextPercentValue)

        let formatTokens: (Int) -> String = { count in
            if count < 1000 { return "\(count)" }
            if count < 10000 { return String(format: "%.1fk", Double(count) / 1000.0) }
            if count < 1_000_000 { return "\(Int(round(Double(count) / 1000.0)))k" }
            if count < 10_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
            return "\(Int(round(Double(count) / 1_000_000.0)))M"
        }

        var pwd = FileManager.default.currentDirectoryPath
        if let home = ProcessInfo.processInfo.environment["HOME"], pwd.hasPrefix(home) {
            pwd = "~" + pwd.dropFirst(home.count)
        }

        if let branch = getCurrentBranch() {
            pwd += " (\(branch))"
        }

        if pwd.count > width {
            let half = max(0, (width / 2) - 2)
            if half > 0 {
                let start = pwd.prefix(half)
                let end = pwd.suffix(max(0, half - 1))
                pwd = "\(start)...\(end)"
            } else {
                pwd = String(pwd.prefix(max(1, width)))
            }
        }

        var statsParts: [String] = []
        if totalInput > 0 { statsParts.append("↑\(formatTokens(totalInput))") }
        if totalOutput > 0 { statsParts.append("↓\(formatTokens(totalOutput))") }
        if totalCacheRead > 0 { statsParts.append("R\(formatTokens(totalCacheRead))") }
        if totalCacheWrite > 0 { statsParts.append("W\(formatTokens(totalCacheWrite))") }
        if totalCost > 0 {
            statsParts.append(String(format: "$%.3f", totalCost))
        }

        let autoIndicator = autoCompactEnabled ? " (auto)" : ""
        let contextDisplay = "\(contextPercent)%/\(formatTokens(contextWindow))\(autoIndicator)"
        let contextText: String
        if contextPercentValue > 90 {
            contextText = theme.fg(.error, contextDisplay)
        } else if contextPercentValue > 70 {
            contextText = theme.fg(.warning, contextDisplay)
        } else {
            contextText = contextDisplay
        }
        statsParts.append(contextText)

        var statsLeft = statsParts.joined(separator: " ")
        let modelName = state.model.id
        var rightSide = modelName
        if state.model.reasoning {
            let thinking = state.thinkingLevel.rawValue
            if thinking != "off" {
                rightSide = "\(modelName) • \(thinking)"
            }
        }

        var statsLeftWidth = visibleWidth(statsLeft)
        let rightSideWidth = visibleWidth(rightSide)

        if statsLeftWidth > width {
            let plain = stripAnsi(statsLeft)
            statsLeft = String(plain.prefix(max(0, width - 3))) + "..."
            statsLeftWidth = visibleWidth(statsLeft)
        }

        let minPadding = 2
        let totalNeeded = statsLeftWidth + minPadding + rightSideWidth
        let statsLine: String
        if totalNeeded <= width {
            let padding = String(repeating: " ", count: width - statsLeftWidth - rightSideWidth)
            statsLine = statsLeft + padding + rightSide
        } else {
            let availableForRight = width - statsLeftWidth - minPadding
            if availableForRight > 3 {
                let plain = stripAnsi(rightSide)
                let truncated = String(plain.prefix(availableForRight))
                let padding = String(repeating: " ", count: max(0, width - statsLeftWidth - truncated.count))
                statsLine = statsLeft + padding + truncated
            } else {
                statsLine = statsLeft
            }
        }

        let dimStatsLeft = theme.fg(.dim, statsLeft)
        let remainder = statsLine.dropFirst(statsLeft.count)
        let dimRemainder = theme.fg(.dim, String(remainder))

        var lines = [theme.fg(.dim, pwd), dimStatsLeft + dimRemainder]

        if !hookStatuses.isEmpty {
            let sortedStatuses = hookStatuses.keys.sorted().compactMap { hookStatuses[$0] }
            let statusLine = sortedStatuses.joined(separator: " ")
            lines.append(truncateToWidth(statusLine, maxWidth: width, ellipsis: theme.fg(.dim, "...")))
        }

        return lines
    }

    private func findGitHeadPath() -> String? {
        var dir = FileManager.default.currentDirectoryPath
        let fm = FileManager.default
        while true {
            let gitHead = (dir as NSString).appendingPathComponent(".git/HEAD")
            if fm.fileExists(atPath: gitHead) {
                return gitHead
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir {
                return nil
            }
            dir = parent
        }
    }

    private func getCurrentBranch() -> String? {
        if branchCacheValid {
            return cachedBranch
        }

        guard let gitHeadPath = findGitHeadPath() else {
            branchCacheValid = true
            cachedBranch = nil
            return nil
        }

        do {
            let content = try String(contentsOfFile: gitHeadPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("ref: refs/heads/") {
                let branch = String(content.dropFirst("ref: refs/heads/".count))
                cachedBranch = branch
            } else {
                cachedBranch = "detached"
            }
        } catch {
            cachedBranch = nil
        }

        branchCacheValid = true
        return cachedBranch
    }
}

private func sanitizeStatusText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "[\r\n\t]", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
}
