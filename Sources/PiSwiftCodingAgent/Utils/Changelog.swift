import Foundation

public struct ChangelogEntry: Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var content: String

    public init(major: Int, minor: Int, patch: Int, content: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.content = content
    }
}

public func parseChangelog(_ changelogPath: String) -> [ChangelogEntry] {
    guard let content = try? String(contentsOfFile: changelogPath, encoding: .utf8) else {
        return []
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var entries: [ChangelogEntry] = []
    var currentLines: [String] = []
    var currentVersion: (major: Int, minor: Int, patch: Int)?
    let regex = try? NSRegularExpression(pattern: "^##\\s+\\[?(\\d+)\\.(\\d+)\\.(\\d+)\\]?", options: [])

    for lineSub in lines {
        let line = String(lineSub)
        if line.hasPrefix("## ") {
            if let currentVersion, !currentLines.isEmpty {
                entries.append(ChangelogEntry(
                    major: currentVersion.major,
                    minor: currentVersion.minor,
                    patch: currentVersion.patch,
                    content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            if let regex {
                let range = NSRange(location: 0, length: line.utf16.count)
                if let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges == 4,
                   let majorRange = Range(match.range(at: 1), in: line),
                   let minorRange = Range(match.range(at: 2), in: line),
                   let patchRange = Range(match.range(at: 3), in: line),
                   let major = Int(line[majorRange]),
                   let minor = Int(line[minorRange]),
                   let patch = Int(line[patchRange]) {
                    currentVersion = (major, minor, patch)
                    currentLines = [line]
                } else {
                    currentVersion = nil
                    currentLines = []
                }
            } else {
                currentVersion = nil
                currentLines = []
            }
        } else if currentVersion != nil {
            currentLines.append(line)
        }
    }

    if let currentVersion, !currentLines.isEmpty {
        entries.append(ChangelogEntry(
            major: currentVersion.major,
            minor: currentVersion.minor,
            patch: currentVersion.patch,
            content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    return entries
}

public func compareVersions(_ lhs: ChangelogEntry, _ rhs: ChangelogEntry) -> Int {
    if lhs.major != rhs.major { return lhs.major - rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor - rhs.minor }
    return lhs.patch - rhs.patch
}

public func getNewEntries(_ entries: [ChangelogEntry], lastVersion: String) -> [ChangelogEntry] {
    let parts = lastVersion.split(separator: ".").map { Int($0) ?? 0 }
    let last = ChangelogEntry(
        major: parts.indices.contains(0) ? parts[0] : 0,
        minor: parts.indices.contains(1) ? parts[1] : 0,
        patch: parts.indices.contains(2) ? parts[2] : 0,
        content: ""
    )
    return entries.filter { compareVersions($0, last) > 0 }
}
