import Foundation
import Testing
import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

@Test func migrateSessionEntriesAddsIds() {
    var entries: [FileEntry] = [
        .session(SessionHeader(type: "session", version: nil, id: "sess-1", timestamp: "2025-01-01T00:00:00Z", cwd: "/tmp", parentSession: nil)),
        .entry(.message(SessionMessageEntry(id: "", parentId: nil, timestamp: "2025-01-01T00:00:01Z", message: userMsg("hi")))),
        .entry(.message(SessionMessageEntry(id: "", parentId: nil, timestamp: "2025-01-01T00:00:02Z", message: assistantMsg("hello")))),
    ]

    migrateSessionEntries(&entries)

    if case .session(let header) = entries[0] {
        #expect(header.version == CURRENT_SESSION_VERSION)
    } else {
        #expect(Bool(false), "Expected session header")
    }

    if case .entry(let first) = entries[1] {
        #expect(first.id.count == 8)
        #expect(first.parentId == nil)
    }
    if case .entry(let second) = entries[2] {
        #expect(second.id.count == 8)
        if case .entry(let first) = entries[1] {
            #expect(second.parentId == first.id)
        }
    }
}

@Test func migrateSessionEntriesIdempotent() {
    var entries: [FileEntry] = [
        .session(SessionHeader(type: "session", version: 2, id: "sess-1", timestamp: "2025-01-01T00:00:00Z", cwd: "/tmp", parentSession: nil)),
        .entry(.message(SessionMessageEntry(id: "abc12345", parentId: nil, timestamp: "2025-01-01T00:00:01Z", message: userMsg("hi")))),
        .entry(.message(SessionMessageEntry(id: "def67890", parentId: "abc12345", timestamp: "2025-01-01T00:00:02Z", message: assistantMsg("hello")))),
    ]

    migrateSessionEntries(&entries)

    if case .entry(let first) = entries[1] {
        #expect(first.id == "abc12345")
    }
    if case .entry(let second) = entries[2] {
        #expect(second.id == "def67890")
        #expect(second.parentId == "abc12345")
    }
}

@Test func loadEntriesFromFileBehaviors() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-test-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let missing = loadEntriesFromFile(URL(fileURLWithPath: tempDir).appendingPathComponent("missing.jsonl").path)
    #expect(missing.isEmpty)

    let emptyFile = URL(fileURLWithPath: tempDir).appendingPathComponent("empty.jsonl")
    try "".write(to: emptyFile, atomically: true, encoding: .utf8)
    #expect(loadEntriesFromFile(emptyFile.path).isEmpty)

    let noHeader = URL(fileURLWithPath: tempDir).appendingPathComponent("no-header.jsonl")
    try "{\"type\":\"message\",\"id\":\"1\"}\n".write(to: noHeader, atomically: true, encoding: .utf8)
    #expect(loadEntriesFromFile(noHeader.path).isEmpty)

    let malformed = URL(fileURLWithPath: tempDir).appendingPathComponent("malformed.jsonl")
    try "not json\n".write(to: malformed, atomically: true, encoding: .utf8)
    #expect(loadEntriesFromFile(malformed.path).isEmpty)

    let valid = URL(fileURLWithPath: tempDir).appendingPathComponent("valid.jsonl")
    let validContent = """
{"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"hi","timestamp":1}}
"""
    try validContent.write(to: valid, atomically: true, encoding: .utf8)
    let entries = loadEntriesFromFile(valid.path)
    #expect(entries.count == 2)

    let mixed = URL(fileURLWithPath: tempDir).appendingPathComponent("mixed.jsonl")
    let mixedContent = """
{"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
not valid json
{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"hi","timestamp":1}}
"""
    try mixedContent.write(to: mixed, atomically: true, encoding: .utf8)
    let mixedEntries = loadEntriesFromFile(mixed.path)
    #expect(mixedEntries.count == 2)
}

@Test func findMostRecentSession() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-test-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    #expect(findMostRecentSession(tempDir) == nil)
    #expect(findMostRecentSession(URL(fileURLWithPath: tempDir).appendingPathComponent("nope").path) == nil)

    try "hello".write(to: URL(fileURLWithPath: tempDir).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "{}".write(to: URL(fileURLWithPath: tempDir).appendingPathComponent("file.json"), atomically: true, encoding: .utf8)
    #expect(findMostRecentSession(tempDir) == nil)

    let invalid = URL(fileURLWithPath: tempDir).appendingPathComponent("invalid.jsonl")
    try "{\"type\":\"message\"}\n".write(to: invalid, atomically: true, encoding: .utf8)
    #expect(findMostRecentSession(tempDir) == nil)

    let session = URL(fileURLWithPath: tempDir).appendingPathComponent("session.jsonl")
    try "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: session, atomically: true, encoding: .utf8)
    #expect(findMostRecentSession(tempDir) == session.path)

    let older = URL(fileURLWithPath: tempDir).appendingPathComponent("older.jsonl")
    let newer = URL(fileURLWithPath: tempDir).appendingPathComponent("newer.jsonl")
    try "{\"type\":\"session\",\"id\":\"old\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: older, atomically: true, encoding: .utf8)
    Thread.sleep(forTimeInterval: 0.02)
    try "{\"type\":\"session\",\"id\":\"new\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n".write(to: newer, atomically: true, encoding: .utf8)
    #expect(findMostRecentSession(tempDir) == newer.path)
}
