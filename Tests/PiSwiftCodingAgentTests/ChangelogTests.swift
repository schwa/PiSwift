import Foundation
import Testing
import PiSwiftCodingAgent

@Test func parseChangelogEntries() throws {
    let tempPath = FileManager.default.temporaryDirectory.appendingPathComponent("pi-changelog-\(UUID().uuidString).md")
    let content = """
# Changelog

## [1.2.3]
- Added thing

## 1.2.2
- Fixed bug
"""
    try content.write(to: tempPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempPath) }

    let entries = parseChangelog(tempPath.path)
    #expect(entries.count == 2)
    #expect(entries[0].major == 1)
    #expect(entries[0].minor == 2)
    #expect(entries[0].patch == 3)
    #expect(entries[1].patch == 2)

    let newEntries = getNewEntries(entries, lastVersion: "1.2.2")
    #expect(newEntries.count == 1)
    #expect(newEntries[0].patch == 3)
}

@Test func sanitizeBinaryOutputStripsControlChars() {
    let raw = "ok\u{0001}\u{0009}\u{000A}done"
    let sanitized = sanitizeBinaryOutput(raw)
    #expect(sanitized == "ok\t\ndone")
}
