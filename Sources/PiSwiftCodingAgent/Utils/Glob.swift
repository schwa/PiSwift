import Foundation

public func globToRegex(_ pattern: String) -> NSRegularExpression? {
    var regex = "^"
    var i = pattern.startIndex
    while i < pattern.endIndex {
        let char = pattern[i]
        if char == "*" {
            let next = pattern.index(after: i)
            if next < pattern.endIndex, pattern[next] == "*" {
                let afterNext = pattern.index(after: next)
                if afterNext < pattern.endIndex, pattern[afterNext] == "/" {
                    regex += "(?:.*/)?"
                    i = pattern.index(after: afterNext)
                    continue
                } else {
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                }
            } else {
                regex += "[^/]*"
                i = next
                continue
            }
        } else if char == "?" {
            regex += "."
        } else if char == "." || char == "+" || char == "(" || char == ")" || char == "|" || char == "^" || char == "$" || char == "{" || char == "}" || char == "[" || char == "]" || char == "\\" {
            regex += "\\\(char)"
        } else {
            regex.append(char)
        }
        i = pattern.index(after: i)
    }
    regex += "$"
    return try? NSRegularExpression(pattern: regex, options: [])
}

public func matchesGlob(_ path: String, _ pattern: String) -> Bool {
    guard let regex = globToRegex(pattern) else {
        return false
    }
    let range = NSRange(location: 0, length: path.utf16.count)
    return regex.firstMatch(in: path, options: [], range: range) != nil
}
