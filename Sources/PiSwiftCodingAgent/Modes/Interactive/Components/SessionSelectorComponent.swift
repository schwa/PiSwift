import Foundation
import MiniTui

private final class SessionList: Component {
    private var allSessions: [SessionInfo]
    private var filteredSessions: [SessionInfo]
    private var selectedIndex: Int = 0
    private let searchInput: Input
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onExit: (() -> Void)?
    private let maxVisible = 5

    init(sessions: [SessionInfo]) {
        self.allSessions = sessions
        self.filteredSessions = sessions
        self.searchInput = Input()
        self.searchInput.onSubmit = { [weak self] _ in
            guard let self else { return }
            if let selected = self.filteredSessions[safe: self.selectedIndex] {
                self.onSelect?(selected.path)
            }
        }
    }

    func invalidate() {}

    func render(width: Int) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: searchInput.render(width: width))
        lines.append("")

        if filteredSessions.isEmpty {
            lines.append(theme.fg(.muted, "  No sessions found"))
            return lines
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredSessions.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredSessions.count)

        for i in startIndex..<endIndex {
            let session = filteredSessions[i]
            let isSelected = i == selectedIndex
            let normalizedMessage = session.firstMessage.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            let cursor = isSelected ? theme.fg(.accent, "› ") : "  "
            let maxMsgWidth = width - 2
            let truncatedMsg = truncateToWidth(normalizedMessage, maxWidth: maxMsgWidth, ellipsis: "...")
            let messageLine = cursor + (isSelected ? theme.bold(truncatedMsg) : truncatedMsg)

            let modified = formatDate(session.modified)
            let msgCount = "\(session.messageCount) message\(session.messageCount == 1 ? "" : "s")"
            let metadata = "  \(modified) · \(msgCount)"
            let metadataLine = theme.fg(.dim, truncateToWidth(metadata, maxWidth: width, ellipsis: ""))

            lines.append(messageLine)
            lines.append(metadataLine)
            lines.append("")
        }

        if startIndex > 0 || endIndex < filteredSessions.count {
            let scrollText = "  (\(selectedIndex + 1)/\(filteredSessions.count))"
            lines.append(theme.fg(.muted, truncateToWidth(scrollText, maxWidth: width, ellipsis: "")))
        }

        return lines
    }

    func handleInput(_ keyData: String) {
        if isArrowUp(keyData) {
            selectedIndex = max(0, selectedIndex - 1)
            return
        }
        if isArrowDown(keyData) {
            selectedIndex = min(filteredSessions.count - 1, selectedIndex + 1)
            return
        }
        if isEnter(keyData) {
            if let selected = filteredSessions[safe: selectedIndex] {
                onSelect?(selected.path)
            }
            return
        }
        if isEscape(keyData) {
            onCancel?()
            return
        }
        if isCtrlC(keyData) {
            onExit?()
            return
        }

        searchInput.handleInput(keyData)
        filterSessions(searchInput.getValue())
    }

    private func filterSessions(_ query: String) {
        filteredSessions = fuzzyFilter(allSessions, query) { $0.allMessagesText }
        selectedIndex = min(selectedIndex, max(0, filteredSessions.count - 1))
    }

    private func formatDate(_ date: Date) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(date)
        let diffMins = Int(diff / 60)
        let diffHours = Int(diff / 3600)
        let diffDays = Int(diff / 86400)

        if diffMins < 1 { return "just now" }
        if diffMins < 60 { return "\(diffMins) minute\(diffMins == 1 ? "" : "s") ago" }
        if diffHours < 24 { return "\(diffHours) hour\(diffHours == 1 ? "" : "s") ago" }
        if diffDays == 1 { return "1 day ago" }
        if diffDays < 7 { return "\(diffDays) days ago" }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

public final class SessionSelectorComponent: Container {
    private let sessionList: SessionList

    public init(
        sessions: [SessionInfo],
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        self.sessionList = SessionList(sessions: sessions)
        super.init()

        addChild(Spacer(1))
        addChild(Text(theme.bold("Resume Session"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())
        addChild(Spacer(1))

        sessionList.onSelect = onSelect
        sessionList.onCancel = onCancel
        sessionList.onExit = onExit

        addChild(sessionList)

        addChild(Spacer(1))
        addChild(DynamicBorder())

        if sessions.isEmpty {
            onCancel()
        }
    }

    public func getSessionList() -> Component {
        sessionList
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
