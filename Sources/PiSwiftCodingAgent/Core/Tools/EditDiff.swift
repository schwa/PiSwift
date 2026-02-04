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

/// Read file as Data and convert to String, preserving BOM information.
/// Swift's String(contentsOfFile:encoding:) automatically strips the BOM,
/// so we need to read as Data first and check for BOM bytes manually.
public func readFilePreservingBom(_ path: String) throws -> (bom: String, text: String) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))

    // Check for UTF-8 BOM: EF BB BF
    let hasBom = data.count >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF

    if hasBom {
        // Convert text after BOM to String
        let textData = data.dropFirst(3)
        guard let text = String(data: Data(textData), encoding: .utf8) else {
            throw NSError(domain: "EditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode file as UTF-8"])
        }
        return ("\u{FEFF}", text)
    } else {
        // No BOM, convert entire data to String
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "EditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode file as UTF-8"])
        }
        return ("", text)
    }
}

// MARK: - Fuzzy Matching

/// Normalize text for fuzzy matching. Applies transformations:
/// - Strip trailing whitespace from each line
/// - Normalize smart quotes to ASCII equivalents
/// - Normalize Unicode dashes/hyphens to ASCII hyphen
/// - Normalize special Unicode spaces to regular space
public func normalizeForFuzzyMatch(_ text: String) -> String {
    var result = text
        // Strip trailing whitespace per line
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            var s = String(line)
            while s.last?.isWhitespace == true { s.removeLast() }
            return s
        }
        .joined(separator: "\n")

    // Smart single quotes → '
    // U+2018 left single quote, U+2019 right single quote,
    // U+201A single low-9 quote, U+201B single high-reversed-9 quote
    result = result.replacingOccurrences(
        of: "[\u{2018}\u{2019}\u{201A}\u{201B}]",
        with: "'",
        options: .regularExpression
    )

    // Smart double quotes → "
    // U+201C left double quote, U+201D right double quote,
    // U+201E double low-9 quote, U+201F double high-reversed-9 quote
    result = result.replacingOccurrences(
        of: "[\u{201C}\u{201D}\u{201E}\u{201F}]",
        with: "\"",
        options: .regularExpression
    )

    // Various dashes/hyphens → -
    // U+2010 hyphen, U+2011 non-breaking hyphen, U+2012 figure dash,
    // U+2013 en-dash, U+2014 em-dash, U+2015 horizontal bar, U+2212 minus
    result = result.replacingOccurrences(
        of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]",
        with: "-",
        options: .regularExpression
    )

    // Special spaces → regular space
    // U+00A0 NBSP, U+2002-U+200A various spaces, U+202F narrow NBSP,
    // U+205F medium math space, U+3000 ideographic space
    result = result.replacingOccurrences(
        of: "[\u{00A0}\u{2002}-\u{200A}\u{202F}\u{205F}\u{3000}]",
        with: " ",
        options: .regularExpression
    )

    return result
}

/// Result of fuzzy text matching
public struct EditFuzzyMatchResult: Sendable {
    /// Whether a match was found
    public var found: Bool
    /// The index where the match starts (in the content that should be used for replacement)
    public var index: Int
    /// Length of the matched text
    public var matchLength: Int
    /// Whether fuzzy matching was used (false = exact match)
    public var usedFuzzyMatch: Bool
    /// The content to use for replacement operations.
    /// When exact match: original content. When fuzzy match: normalized content.
    public var contentForReplacement: String
}

/// Find oldText in content, trying exact match first, then fuzzy match.
/// When fuzzy matching is used, the returned contentForReplacement is the
/// fuzzy-normalized version of the content.
public func fuzzyFindText(_ content: String, _ oldText: String) -> EditFuzzyMatchResult {
    // Try exact match first
    if let exactRange = content.range(of: oldText) {
        let index = content.distance(from: content.startIndex, to: exactRange.lowerBound)
        return EditFuzzyMatchResult(
            found: true,
            index: index,
            matchLength: oldText.count,
            usedFuzzyMatch: false,
            contentForReplacement: content
        )
    }

    // Try fuzzy match - work entirely in normalized space
    let fuzzyContent = normalizeForFuzzyMatch(content)
    let fuzzyOldText = normalizeForFuzzyMatch(oldText)

    guard let fuzzyRange = fuzzyContent.range(of: fuzzyOldText) else {
        return EditFuzzyMatchResult(
            found: false,
            index: -1,
            matchLength: 0,
            usedFuzzyMatch: false,
            contentForReplacement: content
        )
    }

    let index = fuzzyContent.distance(from: fuzzyContent.startIndex, to: fuzzyRange.lowerBound)

    // When fuzzy matching, we work in the normalized space for replacement.
    return EditFuzzyMatchResult(
        found: true,
        index: index,
        matchLength: fuzzyOldText.count,
        usedFuzzyMatch: true,
        contentForReplacement: fuzzyContent
    )
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
