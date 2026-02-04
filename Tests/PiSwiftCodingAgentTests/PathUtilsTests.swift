import Foundation
import Testing
import PiSwiftCodingAgent

@Test func expandPathTilde() {
    let result = expandPath("~")
    #expect(!result.contains("~"))
    #expect(result == getHomeDir())
}

@Test func expandPathTildeSlash() {
    let result = expandPath("~/Documents/file.txt")
    #expect(!result.contains("~/"))
    #expect(result.hasSuffix("/Documents/file.txt"))
}

@Test func expandPathUnicodeSpaces() {
    // Non-breaking space (U+00A0) should become regular space
    let withNBSP = "file\u{00A0}name.txt"
    let result = expandPath(withNBSP)
    #expect(result == "file name.txt")
}

@Test func expandPathNarrowNoBreakSpace() {
    // Narrow no-break space (U+202F) should become regular space
    let withNNBSP = "file\u{202F}name.txt"
    let result = expandPath(withNNBSP)
    #expect(result == "file name.txt")
}

@Test func resolveToCwdAbsolute() {
    let result = resolveToCwd("/absolute/path/file.txt", cwd: "/some/cwd")
    #expect(result == "/absolute/path/file.txt")
}

@Test func resolveToCwdRelative() {
    let result = resolveToCwd("relative/file.txt", cwd: "/some/cwd")
    #expect(result == "/some/cwd/relative/file.txt")
}

private func withTempDir(_ body: (String) throws -> Void) rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("path-utils-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try body(tempDir)
}

@Test func resolveReadPathExistingFile() throws {
    try withTempDir { tempDir in
        let fileName = "test-file.txt"
        let filePath = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName).path
        try "content".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = resolveReadPath(fileName, cwd: tempDir)
        #expect(result == filePath)
    }
}

@Test func resolveReadPathNFCvsNFD() throws {
    try withTempDir { tempDir in
        // NFD: e (U+0065) + combining acute accent (U+0301)
        let nfdFileName = "file\u{0065}\u{0301}.txt"
        // NFC: é as single character (U+00E9)
        let nfcFileName = "file\u{00E9}.txt"

        // Note: On macOS APFS, the filesystem normalizes Unicode automatically
        // so NFD and NFC may resolve to the same path. This test verifies
        // the resolveReadPath function handles this case.

        // Create file with NFD name
        let nfdPath = URL(fileURLWithPath: tempDir).appendingPathComponent(nfdFileName).path
        try "content".write(toFile: nfdPath, atomically: true, encoding: .utf8)

        // User provides NFC path - should find the file (via filesystem normalization or our fallback)
        let result = resolveReadPath(nfcFileName, cwd: tempDir)
        #expect(result.contains(tempDir))
        // The file should be found regardless of which normalization form is used
        #expect(FileManager.default.fileExists(atPath: result))
    }
}

@Test func resolveReadPathCurlyQuotes() throws {
    try withTempDir { tempDir in
        // Curly apostrophe (U+2019)
        let curlyQuoteName = "Capture d\u{2019}cran.txt"
        // Straight apostrophe (U+0027)
        let straightQuoteName = "Capture d'cran.txt"

        #expect(curlyQuoteName != straightQuoteName)

        // Create file with curly quote name
        let curlyPath = URL(fileURLWithPath: tempDir).appendingPathComponent(curlyQuoteName).path
        try "content".write(toFile: curlyPath, atomically: true, encoding: .utf8)

        // User provides straight quote path - should find curly quote file
        let result = resolveReadPath(straightQuoteName, cwd: tempDir)
        #expect(result == curlyPath)
    }
}

@Test func resolveReadPathMacOSScreenshotNarrowSpace() throws {
    try withTempDir { tempDir in
        // macOS uses narrow no-break space (U+202F) before AM/PM
        let macosName = "Screenshot 2024-01-01 at 10.00.00\u{202F}AM.png"
        let userName = "Screenshot 2024-01-01 at 10.00.00 AM.png"

        let macosPath = URL(fileURLWithPath: tempDir).appendingPathComponent(macosName).path
        try "content".write(toFile: macosPath, atomically: true, encoding: .utf8)

        // User provides regular space path
        let result = resolveReadPath(userName, cwd: tempDir)
        #expect(result == macosPath)
    }
}

@Test func resolveReadPathCombinedNFCCurlyQuote() throws {
    try withTempDir { tempDir in
        // NFC + curly quote (how APFS stores it)
        let nfcCurlyName = "Capture d\u{2019}\u{00E9}cran.txt"
        // NFC + straight quote (user input)
        let nfcStraightName = "Capture d'\u{00E9}cran.txt"

        #expect(nfcCurlyName != nfcStraightName)

        let curlyPath = URL(fileURLWithPath: tempDir).appendingPathComponent(nfcCurlyName).path
        try "content".write(toFile: curlyPath, atomically: true, encoding: .utf8)

        let result = resolveReadPath(nfcStraightName, cwd: tempDir)
        #expect(result == curlyPath)
    }
}
