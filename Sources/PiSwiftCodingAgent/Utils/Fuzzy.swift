import Foundation

public struct FuzzyMatchResult: Sendable {
    public var matches: Bool
    public var score: Double

    public init(matches: Bool, score: Double) {
        self.matches = matches
        self.score = score
    }
}

public func fuzzyMatch(_ query: String, _ text: String) -> FuzzyMatchResult {
    let queryLower = query.lowercased()
    let textLower = text.lowercased()

    if queryLower.isEmpty {
        return FuzzyMatchResult(matches: true, score: 0)
    }

    if queryLower.count > textLower.count {
        return FuzzyMatchResult(matches: false, score: 0)
    }

    var queryIndex = 0
    var score = 0.0
    var lastMatchIndex = -1
    var consecutiveMatches = 0

    let textChars = Array(textLower)
    let queryChars = Array(queryLower)

    for i in 0..<textChars.count {
        guard queryIndex < queryChars.count else { break }

        if textChars[i] == queryChars[queryIndex] {
            let isWordBoundary: Bool
            if i == 0 {
                isWordBoundary = true
            } else {
                let prev = textChars[i - 1]
                isWordBoundary = prev.isWhitespace || prev == "-" || prev == "_" || prev == "." || prev == "/"
            }

            if lastMatchIndex == i - 1 {
                consecutiveMatches += 1
                score -= Double(consecutiveMatches) * 5.0
            } else {
                consecutiveMatches = 0
                if lastMatchIndex >= 0 {
                    score += Double(i - lastMatchIndex - 1) * 2.0
                }
            }

            if isWordBoundary {
                score -= 10.0
            }

            score += Double(i) * 0.1

            lastMatchIndex = i
            queryIndex += 1
        }
    }

    if queryIndex < queryChars.count {
        return FuzzyMatchResult(matches: false, score: 0)
    }

    return FuzzyMatchResult(matches: true, score: score)
}

public func fuzzyFilter<T>(
    _ items: [T],
    _ query: String,
    getText: (T) -> String
) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return items
    }

    let tokens = trimmed.split { $0.isWhitespace }.map { String($0) }.filter { !$0.isEmpty }
    if tokens.isEmpty {
        return items
    }

    var results: [(item: T, score: Double)] = []

    for item in items {
        let text = getText(item)
        var totalScore = 0.0
        var allMatch = true

        for token in tokens {
            let match = fuzzyMatch(token, text)
            if match.matches {
                totalScore += match.score
            } else {
                allMatch = false
                break
            }
        }

        if allMatch {
            results.append((item, totalScore))
        }
    }

    results.sort { $0.score < $1.score }
    return results.map { $0.item }
}
