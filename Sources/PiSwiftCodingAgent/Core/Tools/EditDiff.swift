import Foundation

public enum LineEnding: String {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

public func detectLineEnding(_ content: String) -> LineEnding {
    if content.contains("\r\n") {
        return .crlf
    }
    if content.contains("\r") {
        return .cr
    }
    return .lf
}

public func normalizeToLF(_ content: String) -> String {
    content
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

public func restoreLineEndings(_ content: String, _ ending: LineEnding) -> String {
    switch ending {
    case .lf:
        return content
    case .crlf:
        return content.replacingOccurrences(of: "\n", with: "\r\n")
    case .cr:
        return content.replacingOccurrences(of: "\n", with: "\r")
    }
}

public func stripBom(_ content: String) -> (bom: String, text: String) {
    if content.hasPrefix("\u{FEFF}") {
        let start = content.index(after: content.startIndex)
        return ("\u{FEFF}", String(content[start...]))
    }
    return ("", content)
}

public func generateDiffString(_ oldText: String, _ newText: String) -> (diff: String, firstChangedLine: Int?) {
    let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
    let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)
    let limit = min(oldLines.count, newLines.count)
    var firstChanged: Int? = nil
    for i in 0..<limit {
        if oldLines[i] != newLines[i] {
            firstChanged = i + 1
            break
        }
    }
    if firstChanged == nil && oldLines.count != newLines.count {
        firstChanged = limit + 1
    }

    let diff = "- \(oldText)\n+ \(newText)"
    return (diff, firstChanged)
}
