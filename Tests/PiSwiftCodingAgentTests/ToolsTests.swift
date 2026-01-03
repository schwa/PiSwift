import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func runTool(_ tool: AgentTool, _ id: String, _ params: [String: AnyCodable]) async throws -> AgentToolResult {
    try await tool.execute(id, params, nil, nil)
}

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("coding-agent-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

@Test func readToolReadsFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("test.txt").path
        let content = "Hello, world!\nLine 2\nLine 3"
        try content.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(readTool, "test-call-1", ["path": AnyCodable(testFile)])
        #expect(textOutput(result) == content)
        #expect(result.details == nil)
    }
}

@Test func readToolNonExistent() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("missing.txt").path
        do {
            _ = try await runTool(readTool, "test-call-2", ["path": AnyCodable(testFile)])
            #expect(Bool(false), "Expected read to throw")
        } catch {
            #expect(error.localizedDescription.lowercased().contains("not found") || error.localizedDescription.lowercased().contains("no such file"))
        }
    }
}

@Test func readToolTruncatesByLines() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("large.txt").path
        let lines = (0..<2500).map { "Line \($0 + 1)" }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(readTool, "test-call-3", ["path": AnyCodable(testFile)])
        let output = textOutput(result)
        #expect(output.contains("Line 1"))
        #expect(output.contains("Line 2000"))
        #expect(!output.contains("Line 2001"))
        #expect(output.contains("Use offset=2001"))

        let details = result.details?.value as? [String: Any]
        let truncation = details?["truncation"] as? [String: Any]
        #expect(truncation?["truncated"] as? Bool == true)
        #expect(truncation?["truncatedBy"] as? String == "lines")
        #expect(truncation?["totalLines"] as? Int == 2500)
        #expect(truncation?["outputLines"] as? Int == 2000)
    }
}

@Test func readToolTruncatesByBytes() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("large-bytes.txt").path
        let lines = (0..<500).map { "Line \($0 + 1): " + String(repeating: "x", count: 200) }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(readTool, "test-call-4", ["path": AnyCodable(testFile)])
        let output = textOutput(result)
        #expect(output.contains("Line 1:"))
        #expect(output.contains("limit"))
    }
}

@Test func readToolOffsetAndLimit() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("offset.txt").path
        let lines = (0..<100).map { "Line \($0 + 1)" }.joined(separator: "\n")
        try lines.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(readTool, "test-call-5", ["path": AnyCodable(testFile), "offset": AnyCodable(51)])
        let output = textOutput(result)
        #expect(!output.contains("Line 50"))
        #expect(output.contains("Line 51"))
        #expect(output.contains("Line 100"))

        let limited = try await runTool(readTool, "test-call-6", ["path": AnyCodable(testFile), "limit": AnyCodable(10)])
        let limitedOutput = textOutput(limited)
        #expect(limitedOutput.contains("Line 10"))
        #expect(!limitedOutput.contains("Line 11"))
        #expect(limitedOutput.contains("Use offset=11"))

        let offsetLimit = try await runTool(readTool, "test-call-7", [
            "path": AnyCodable(testFile),
            "offset": AnyCodable(41),
            "limit": AnyCodable(20),
        ])
        let offsetOutput = textOutput(offsetLimit)
        #expect(offsetOutput.contains("Line 41"))
        #expect(offsetOutput.contains("Line 60"))
        #expect(!offsetOutput.contains("Line 61"))
        #expect(offsetOutput.contains("Use offset=61"))
    }
}

@Test func readToolOffsetBeyondEnd() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("short.txt").path
        try? "Line 1\nLine 2\nLine 3".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(readTool, "test-call-8", ["path": AnyCodable(testFile), "offset": AnyCodable(100)])
            #expect(Bool(false), "Expected offset error")
        } catch {
            #expect(error.localizedDescription.contains("Offset 100"))
        }
    }
}

@Test func readToolImageDetection() async throws {
    try await withTempDir { dir in
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2Z0AAAAASUVORK5CYII="
        let pngData = Data(base64Encoded: pngBase64) ?? Data()
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("image.txt").path
        try pngData.write(to: URL(fileURLWithPath: testFile))

        let result = try await runTool(readTool, "test-call-img-1", ["path": AnyCodable(testFile)])
        if let first = result.content.first {
            if case .text = first {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected first content block to be text")
            }
        }
        #expect(textOutput(result).contains("Read image file [image/png]"))
        let imageBlock = result.content.first { block in
            if case .image = block { return true }
            return false
        }
        #expect(imageBlock != nil)
    }
}

@Test func readToolImageExtensionNonImage() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("not-an-image.png").path
        try "definitely not a png".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(readTool, "test-call-img-2", ["path": AnyCodable(testFile)])
        #expect(textOutput(result).contains("definitely not a png"))
        let hasImage = result.content.contains { block in
            if case .image = block { return true }
            return false
        }
        #expect(!hasImage)
    }
}

@Test func writeToolWritesFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("write-test.txt").path
        let result = try await runTool(writeTool, "test-call-3", ["path": AnyCodable(testFile), "content": AnyCodable("Test content")])
        let output = textOutput(result)
        #expect(output.contains("Successfully wrote"))
        #expect(output.contains(testFile))
    }
}

@Test func writeToolCreatesParents() async throws {
    try await withTempDir { dir in
        let nested = URL(fileURLWithPath: dir).appendingPathComponent("nested/dir/test.txt").path
        let result = try await runTool(writeTool, "test-call-4", ["path": AnyCodable(nested), "content": AnyCodable("Nested content")])
        #expect(textOutput(result).contains("Successfully wrote"))
    }
}

@Test func editToolReplacesText() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try "Hello, world!".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(editTool, "test-call-5", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("world"),
            "newText": AnyCodable("testing"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))
        let details = result.details?.value as? [String: Any]
        #expect(details?["diff"] as? String != nil)
    }
}

@Test func editToolNotFound() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try? "Hello, world!".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(editTool, "test-call-6", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("nonexistent"),
                "newText": AnyCodable("testing"),
            ])
            #expect(Bool(false), "Expected edit failure")
        } catch {
            #expect(error.localizedDescription.contains("Could not find the exact text"))
        }
    }
}

@Test func editToolMultipleOccurrences() async {
    await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("edit-test.txt").path
        try? "foo foo foo".write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            _ = try await runTool(editTool, "test-call-7", [
                "path": AnyCodable(testFile),
                "oldText": AnyCodable("foo"),
                "newText": AnyCodable("bar"),
            ])
            #expect(Bool(false), "Expected edit failure")
        } catch {
            #expect(error.localizedDescription.contains("Found 3 occurrences"))
        }
    }
}

@Test func bashToolExecutes() async throws {
    let result = try await runTool(bashTool, "test-call-8", ["command": AnyCodable("echo 'test output'")])
    #expect(textOutput(result).contains("test output"))
}

@Test func bashToolErrors() async {
    do {
        _ = try await runTool(bashTool, "test-call-9", ["command": AnyCodable("exit 1")])
        #expect(Bool(false), "Expected bash failure")
    } catch {
        #expect(error.localizedDescription.contains("code 1") || error.localizedDescription.contains("Command"))
    }
}

@Test func bashToolTimeout() async {
    do {
        _ = try await runTool(bashTool, "test-call-10", ["command": AnyCodable("sleep 5"), "timeout": AnyCodable(1)])
        #expect(Bool(false), "Expected timeout")
    } catch {
        #expect(error.localizedDescription.lowercased().contains("timed out"))
    }
}

@Test func grepToolSingleFile() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("example.txt").path
        try "first line\nmatch line\nlast line".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(grepTool, "test-call-11", [
            "pattern": AnyCodable("match"),
            "path": AnyCodable(testFile),
        ])
        #expect(textOutput(result).contains("example.txt:2: match line"))
    }
}

@Test func grepToolContextLimit() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("context.txt").path
        let content = ["before", "match one", "after", "middle", "match two", "after two"].joined(separator: "\n")
        try content.write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(grepTool, "test-call-12", [
            "pattern": AnyCodable("match"),
            "path": AnyCodable(testFile),
            "limit": AnyCodable(1),
            "context": AnyCodable(1),
        ])
        let output = textOutput(result)
        #expect(output.contains("context.txt-1- before"))
        #expect(output.contains("context.txt:2: match one"))
        #expect(output.contains("context.txt-3- after"))
        #expect(output.contains("limit reached"))
        #expect(!output.contains("match two"))
    }
}

@Test func findToolIncludesHidden() async throws {
    try await withTempDir { dir in
        let hiddenDir = URL(fileURLWithPath: dir).appendingPathComponent(".secret")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "hidden".write(to: hiddenDir.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        try "visible".write(to: URL(fileURLWithPath: dir).appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let result = try await runTool(findTool, "test-call-13", [
            "pattern": AnyCodable("**/*.txt"),
            "path": AnyCodable(dir),
        ])
        let lines = textOutput(result).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("visible.txt"))
        #expect(lines.contains(".secret/hidden.txt"))
    }
}

@Test func findToolRespectsGitignore() async throws {
    try await withTempDir { dir in
        try "ignored.txt\n".write(to: URL(fileURLWithPath: dir).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "ignored".write(to: URL(fileURLWithPath: dir).appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "kept".write(to: URL(fileURLWithPath: dir).appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)

        let result = try await runTool(findTool, "test-call-14", [
            "pattern": AnyCodable("**/*.txt"),
            "path": AnyCodable(dir),
        ])
        let output = textOutput(result)
        #expect(output.contains("kept.txt"))
        #expect(!output.contains("ignored.txt"))
    }
}

@Test func lsToolListsDotfiles() async throws {
    try await withTempDir { dir in
        try "secret".write(to: URL(fileURLWithPath: dir).appendingPathComponent(".hidden-file"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir).appendingPathComponent(".hidden-dir"), withIntermediateDirectories: true)

        let result = try await runTool(lsTool, "test-call-15", ["path": AnyCodable(dir)])
        let output = textOutput(result)
        #expect(output.contains(".hidden-file"))
        #expect(output.contains(".hidden-dir/"))
    }
}

@Test func editToolCRLFHandling() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("crlf-test.txt").path
        try "line one\r\nline two\r\nline three\r\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        let result = try await runTool(editTool, "test-crlf-1", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("line two\n"),
            "newText": AnyCodable("replaced line\n"),
        ])
        #expect(textOutput(result).contains("Successfully replaced"))

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content == "line one\r\nreplaced line\r\nline three\r\n")
    }
}

@Test func editToolPreservesLF() async throws {
    try await withTempDir { dir in
        let testFile = URL(fileURLWithPath: dir).appendingPathComponent("lf-test.txt").path
        try "first\nsecond\nthird\n".write(toFile: testFile, atomically: true, encoding: .utf8)

        _ = try await runTool(editTool, "test-lf-1", [
            "path": AnyCodable(testFile),
            "oldText": AnyCodable("second\n"),
            "newText": AnyCodable("REPLACED\n"),
        ])

        let content = try String(contentsOfFile: testFile, encoding: .utf8)
        #expect(content == "first\nREPLACED\nthird\n")
    }
}
