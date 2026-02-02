import Foundation
import Testing
import PiSwiftCodingAgent

@Test func settingsPreservesExternalEdits() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let initial = """
    {"theme":"dark","extra":{"foo":"bar"},"compaction":{"enabled":true,"reserveTokens":1234,"keepRecentTokens":5678}}
    """
    try initial.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setCompactionEnabled(false)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    let extra = json?["extra"] as? [String: Any]
    #expect(extra?["foo"] as? String == "bar")

    let compaction = json?["compaction"] as? [String: Any]
    #expect(compaction?["enabled"] as? Bool == false)
    #expect(compaction?["reserveTokens"] as? Int == 1234)
    #expect(compaction?["keepRecentTokens"] as? Int == 5678)
    #expect(json?["theme"] as? String == "dark")
}

@Test func settingsInvalidJsonDoesNotOverwrite() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-bad-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path
    let invalid = "{"
    try invalid.data(using: .utf8)?.write(to: URL(fileURLWithPath: settingsPath))

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setTheme("light")

    let contents = try String(contentsOfFile: settingsPath, encoding: .utf8)
    #expect(contents == invalid)
}

@Test func settingsQuietStartupRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-settings-quiet-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let settingsPath = URL(fileURLWithPath: tempDir).appendingPathComponent("settings.json").path

    let manager = SettingsManager.create(tempDir, tempDir)
    manager.setQuietStartup(true)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["quietStartup"] as? Bool == true)

    let reloaded = SettingsManager.create(tempDir, tempDir)
    #expect(reloaded.getQuietStartup() == true)
}
