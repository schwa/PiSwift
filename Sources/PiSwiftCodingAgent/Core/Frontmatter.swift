import Foundation

/// Result of parsing YAML frontmatter from a markdown file
public struct FrontmatterResult: Sendable {
    /// Parsed key-value pairs from frontmatter
    public var frontmatter: [String: String]
    /// Keys in the order they appeared (for validation)
    public var keys: [String]
    /// Body content after frontmatter
    public var body: String

    public init(frontmatter: [String: String] = [:], keys: [String] = [], body: String) {
        self.frontmatter = frontmatter
        self.keys = keys
        self.body = body
    }
}

/// Parses YAML frontmatter from markdown content.
///
/// Supports:
/// - Standard `key: value` pairs
/// - Quoted values (single and double quotes)
/// - YAML block scalars: `|` (literal, preserves newlines) and `>` (folded, joins with spaces)
/// - CRLF and CR line ending normalization
///
/// - Parameter content: The markdown content with optional frontmatter
/// - Returns: Parsed frontmatter and body content
public func parseFrontmatter(_ content: String) -> FrontmatterResult {
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    guard normalized.hasPrefix("---") else {
        return FrontmatterResult(body: normalized)
    }
    guard let endRange = normalized.range(of: "\n---", options: [], range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex) else {
        return FrontmatterResult(body: normalized)
    }
    let frontmatterBlock = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound])
    let bodyStart = normalized.index(endRange.lowerBound, offsetBy: 4)
    let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

    var frontmatter: [String: String] = [:]
    var keys: [String] = []
    let lines = frontmatterBlock.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            i += 1
            continue
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else {
            i += 1
            continue
        }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        var value = parts[1].trimmingCharacters(in: .whitespaces)

        // Handle YAML block scalars: | (literal) or > (folded)
        if value == "|" || value == ">" {
            let isFolded = value == ">"
            var blockLines: [String] = []
            i += 1

            // Collect indented lines
            while i < lines.count {
                let nextLine = lines[i]
                // Check if line is indented (starts with whitespace) or is empty
                let hasIndent = nextLine.hasPrefix(" ") || nextLine.hasPrefix("\t")
                let isEmpty = nextLine.trimmingCharacters(in: .whitespaces).isEmpty

                if hasIndent || (isEmpty && i + 1 < lines.count) {
                    // Strip common leading whitespace (YAML uses first indented line to determine indent)
                    if blockLines.isEmpty && hasIndent {
                        // First content line - trim leading whitespace
                        blockLines.append(nextLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
                    } else if isEmpty {
                        blockLines.append("")
                    } else {
                        // Subsequent lines - try to strip same indent as first line
                        blockLines.append(nextLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
                    }
                    i += 1
                } else {
                    break
                }
            }

            // Join lines based on block style
            if isFolded {
                // Folded style: replace single newlines with spaces, preserve double newlines
                value = blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            } else {
                // Literal style: preserve newlines
                value = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }

            keys.append(key)
            frontmatter[key] = value
            continue
        }

        // Handle quoted values
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }

        keys.append(key)
        frontmatter[key] = value
        i += 1
    }

    return FrontmatterResult(frontmatter: frontmatter, keys: keys, body: body)
}
