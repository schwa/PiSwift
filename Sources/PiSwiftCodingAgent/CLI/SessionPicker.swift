import Foundation

public func selectSession(_ sessions: [SessionInfo]) -> String? {
    guard !sessions.isEmpty else { return nil }

    print("Select a session:")
    for (index, session) in sessions.enumerated() {
        let summary = session.firstMessage.isEmpty ? "(no messages)" : session.firstMessage
        print("[\(index + 1)] \(summary) (\(session.path))")
    }
    print("Enter number (or press Enter to cancel): ", terminator: "")

    guard let input = readLine(), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    guard let selection = Int(input), selection > 0, selection <= sessions.count else {
        return nil
    }
    return sessions[selection - 1].path
}
