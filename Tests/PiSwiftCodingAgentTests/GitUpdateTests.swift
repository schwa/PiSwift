import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - Git update tests

/// Tests for git-based extension updates, specifically handling force-push scenarios.
///
/// These tests verify that DefaultPackageManager.update() handles:
/// - Normal git updates (no force-push)
/// - Force-pushed remotes gracefully
/// - Pinned sources (shouldn't update)

// MARK: - Test helpers

private func git(_ args: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

    if process.terminationStatus != 0 {
        throw GitTestError.commandFailed("git \(args.joined(separator: " ")): \(output)")
    }

    return output
}

private func createCommit(repoDir: String, filename: String, content: String, message: String) throws -> String {
    let filePath = URL(fileURLWithPath: repoDir).appendingPathComponent(filename).path
    try content.write(toFile: filePath, atomically: true, encoding: .utf8)
    _ = try git(["add", filename], cwd: repoDir)
    _ = try git(["commit", "-m", message], cwd: repoDir)
    return try git(["rev-parse", "HEAD"], cwd: repoDir)
}

private func getCurrentCommit(repoDir: String) throws -> String {
    try git(["rev-parse", "HEAD"], cwd: repoDir)
}

private func getFileContent(repoDir: String, filename: String) throws -> String {
    let filePath = URL(fileURLWithPath: repoDir).appendingPathComponent(filename).path
    return try String(contentsOfFile: filePath, encoding: .utf8)
}

private enum GitTestError: Error {
    case commandFailed(String)
}

// MARK: - Test fixture

private final class GitUpdateTestFixture {
    let tempDir: String
    let remoteDir: String
    let agentDir: String
    let installedDir: String
    let settingsManager: SettingsManager
    let packageManager: DefaultPackageManager
    let gitSource = "git:github.com/test/extension"

    init() throws {
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-update-test-\(uuid)")
            .path

        remoteDir = URL(fileURLWithPath: tempDir).appendingPathComponent("remote").path
        agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path

        // This matches the path structure: agentDir/git/<host>/<path>
        installedDir = URL(fileURLWithPath: agentDir)
            .appendingPathComponent("git")
            .appendingPathComponent("github.com")
            .appendingPathComponent("test")
            .appendingPathComponent("extension")
            .path

        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

        settingsManager = SettingsManager.inMemory()
        packageManager = DefaultPackageManager(cwd: tempDir, agentDir: agentDir, settingsManager: settingsManager)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    /// Sets up a "remote" repository and clones it to the installed directory.
    /// This simulates what packageManager.install() would do.
    func setupRemoteAndInstall() throws {
        // Create "remote" repository
        try FileManager.default.createDirectory(atPath: remoteDir, withIntermediateDirectories: true)
        _ = try git(["init"], cwd: remoteDir)
        _ = try git(["config", "user.email", "test@test.com"], cwd: remoteDir)
        _ = try git(["config", "user.name", "Test"], cwd: remoteDir)
        _ = try createCommit(repoDir: remoteDir, filename: "extension.ts", content: "// v1", message: "Initial commit")

        // Clone to installed directory (simulating what install() does)
        let parentDir = URL(fileURLWithPath: installedDir).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        _ = try git(["clone", remoteDir, installedDir], cwd: tempDir)
        _ = try git(["config", "user.email", "test@test.com"], cwd: installedDir)
        _ = try git(["config", "user.name", "Test"], cwd: installedDir)

        // Add to settings so update() processes this source
        settingsManager.setPackages([.simple(gitSource)])
    }
}

// MARK: - Normal update tests

@Test func gitUpdateToLatestCommitWhenRemoteHasNewCommits() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v1")

    // Add a new commit to remote
    let newCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2",
        message: "Second commit"
    )

    // Update via package manager
    try await fixture.packageManager.update(nil)

    // Verify update succeeded
    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == newCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2")
}

@Test func gitUpdateHandlesMultipleCommitsAhead() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Add multiple commits to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Second commit")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "Third commit")
    let latestCommit = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v4", message: "Fourth commit")

    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == latestCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v4")
}

// MARK: - Force-push scenario tests

@Test func gitUpdateRecoversWhenRemoteHistoryIsRewritten() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()
    let initialCommit = try getCurrentCommit(repoDir: fixture.remoteDir)

    // Add commit to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Commit to keep")

    // Update to get the new commit
    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2")

    // Now force-push to rewrite history on remote
    _ = try git(["reset", "--hard", initialCommit], cwd: fixture.remoteDir)
    let rewrittenCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2-rewritten",
        message: "Rewritten commit"
    )

    // Update should succeed despite force-push
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == rewrittenCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2-rewritten")
}

@Test func gitUpdateRecoversWhenLocalCommitNoLongerExistsInRemote() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Add commits to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Commit A")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "Commit B")

    // Update to get all commits
    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v3")

    // Force-push remote to remove commits A and B
    _ = try git(["reset", "--hard", "HEAD~2"], cwd: fixture.remoteDir)
    let newCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2-new",
        message: "New commit replacing A and B"
    )

    // Update should succeed - the commits we had locally no longer exist
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == newCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2-new")
}

@Test func gitUpdateHandlesCompleteHistoryRewrite() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Remote gets several commits
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "v2")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "v3")

    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v3")

    // Maintainer force-pushes completely different history
    _ = try git(["reset", "--hard", "HEAD~2"], cwd: fixture.remoteDir)
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// rewrite-a", message: "Rewrite A")
    let finalCommit = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// rewrite-b", message: "Rewrite B")

    // Should handle this gracefully
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == finalCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// rewrite-b")
}

// MARK: - Pinned source tests

@Test func gitUpdateSkipsPinnedSources() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()
    let initialCommit = try getCurrentCommit(repoDir: fixture.installedDir)

    // Reconfigure with pinned ref
    fixture.settingsManager.setPackages([.simple("\(fixture.gitSource)@\(initialCommit)")])

    // Add new commit to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Second commit")

    // Update should be skipped for pinned sources
    try await fixture.packageManager.update(nil)

    // Should still be on initial commit
    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == initialCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v1")
}
