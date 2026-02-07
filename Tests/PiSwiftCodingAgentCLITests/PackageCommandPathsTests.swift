import Foundation
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private func readSettingsPackages(_ settingsPath: String) -> [String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let packages = json["packages"] as? [Any] else {
        return []
    }
    return packages.compactMap { $0 as? String }
}

@MainActor @Test(.disabled("Flaky: changeCurrentDirectoryPath interferes with parallel tests"))
func packageCommandsPersistRelativeLocalPaths() async {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-package-commands-\(UUID().uuidString)").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let packageDir = URL(fileURLWithPath: projectDir).appendingPathComponent("packages/local-package").path

    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: packageDir, withIntermediateDirectories: true)

    let originalCwd = FileManager.default.currentDirectoryPath
    let originalAgentDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
    setenv(ENV_AGENT_DIR, agentDir, 1)
    FileManager.default.changeCurrentDirectoryPath(projectDir)
    defer {
        FileManager.default.changeCurrentDirectoryPath(originalCwd)
        if let originalAgentDir {
            setenv(ENV_AGENT_DIR, originalAgentDir, 1)
        } else {
            unsetenv(ENV_AGENT_DIR)
        }
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    _ = await handlePackageCommand(["install", "./packages/local-package"])

    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    let packages = readSettingsPackages(settingsPath)
    #expect(packages.count == 1)
    guard let stored = packages.first else {
        Issue.record("Expected stored package path")
        return
    }
    let resolvedFromSettings = URL(fileURLWithPath: agentDir).appendingPathComponent(stored).resolvingSymlinksInPath().path
    let resolvedPackageDir = URL(fileURLWithPath: packageDir).resolvingSymlinksInPath().path
    #expect(resolvedFromSettings == resolvedPackageDir)
}

@MainActor @Test(.disabled("Flaky: changeCurrentDirectoryPath interferes with parallel tests"))
func packageCommandsRemoveTrailingSlash() async {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-package-commands-remove-\(UUID().uuidString)").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let packageDir = URL(fileURLWithPath: tempDir).appendingPathComponent("local-package").path

    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: packageDir, withIntermediateDirectories: true)

    let originalCwd = FileManager.default.currentDirectoryPath
    let originalAgentDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
    setenv(ENV_AGENT_DIR, agentDir, 1)
    FileManager.default.changeCurrentDirectoryPath(projectDir)
    defer {
        FileManager.default.changeCurrentDirectoryPath(originalCwd)
        if let originalAgentDir {
            setenv(ENV_AGENT_DIR, originalAgentDir, 1)
        } else {
            unsetenv(ENV_AGENT_DIR)
        }
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    _ = await handlePackageCommand(["install", "\(packageDir)/"])

    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    #expect(readSettingsPackages(settingsPath).count == 1)

    _ = await handlePackageCommand(["remove", "\(packageDir)/"])
    #expect(readSettingsPackages(settingsPath).isEmpty)
}
