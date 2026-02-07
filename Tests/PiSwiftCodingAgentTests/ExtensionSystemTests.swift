import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// MARK: - Helpers

private func fixturesRoot() -> String {
    if let resourceURL = Bundle.module.resourceURL {
        return resourceURL.appendingPathComponent("fixtures").path
    }
    let filePath = URL(fileURLWithPath: #filePath)
    return filePath.deletingLastPathComponent().appendingPathComponent("fixtures").path
}

private func extensionFixture(_ name: String) -> String {
    URL(fileURLWithPath: fixturesRoot()).appendingPathComponent("extensions/\(name)").path
}

/// Resolve the SDK paths for tests from the SPM build artifacts.
private func testSDKPaths() -> ExtensionCompiler.SDKPaths? {
    func checkBuildDir(_ buildDir: String) -> ExtensionCompiler.SDKPaths? {
        let modulesDir = (buildDir as NSString).appendingPathComponent("Modules")
        let moduleFile = (modulesDir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        let libFile = (buildDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        if FileManager.default.fileExists(atPath: moduleFile),
           FileManager.default.fileExists(atPath: libFile) {
            return ExtensionCompiler.SDKPaths(modulePath: modulesDir, libPath: buildDir)
        }
        return nil
    }

    func walkUp(from baseDir: String) -> ExtensionCompiler.SDKPaths? {
        var dir = baseDir as NSString
        for _ in 0..<10 {
            for config in ["debug", "release"] {
                let buildDir = (dir as NSString).appendingPathComponent(".build/\(config)")
                if let result = checkBuildDir(buildDir) { return result }
            }
            dir = dir.deletingLastPathComponent as NSString
        }
        return nil
    }

    // 1. The test bundle lives inside .build/<triple>/debug/  —  the SDK
    //    artifacts (.swiftmodule + .dylib) are in that same directory.
    if let resourceURL = Bundle.module.resourceURL {
        let debugDir = resourceURL.deletingLastPathComponent().path
        if let paths = checkBuildDir(debugDir) { return paths }
    }

    // 2. Walk up from #filePath (absolute source tree path).
    //    NOTE: #file in Swift 6 returns a module-relative path; use #filePath.
    let filePath = (#filePath as NSString).deletingLastPathComponent
    if let paths = walkUp(from: filePath) { return paths }

    // 3. Fall back to ExtensionCompiler's own resolution
    return ExtensionCompiler.resolveSDKPaths()
}

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-ext-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

// MARK: - ExtensionCompiler Tests

@Test func compilerContentHashIsDeterministic() throws {
    let data = Data("hello world".utf8)
    let hash1 = ExtensionCompiler.sha256(data)
    let hash2 = ExtensionCompiler.sha256(data)
    #expect(hash1 == hash2)
    #expect(hash1.count == 64) // SHA-256 produces 64 hex chars
}

@Test func compilerContentHashDiffersForDifferentInput() throws {
    let hash1 = ExtensionCompiler.sha256(Data("hello".utf8))
    let hash2 = ExtensionCompiler.sha256(Data("world".utf8))
    #expect(hash1 != hash2)
}

@Test func compilerResolvesSDKPaths() throws {
    let paths = testSDKPaths()
    #expect(paths != nil, "SDK paths should be resolvable from test environment")
    if let paths {
        let modulePath = (paths.modulePath as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        #expect(FileManager.default.fileExists(atPath: modulePath))
        let libPath = (paths.libPath as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        #expect(FileManager.default.fileExists(atPath: libPath))
    }
}

@Test func compilerCompilesSingleFile() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(FileManager.default.fileExists(atPath: dylibPath))
        #expect(dylibPath.hasSuffix(".dylib"))
        #expect(dylibPath.hasPrefix(cacheDir))
    }
}

@Test func compilerCacheHitOnSecondCompilation() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")

        let path1 = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        let attrs1 = try FileManager.default.attributesOfItem(atPath: path1)
        let mtime1 = attrs1[.modificationDate] as? Date

        // Small delay to ensure mtime would differ on a recompile
        try await Task.sleep(for: .milliseconds(50))

        let path2 = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        let attrs2 = try FileManager.default.attributesOfItem(atPath: path2)
        let mtime2 = attrs2[.modificationDate] as? Date

        #expect(path1 == path2, "Cache should return the same path")
        #expect(mtime1 == mtime2, "File should not be recompiled (same mtime)")
    }
}

@Test func compilerReportsCompilationErrors() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("bad-syntax.swift")

        do {
            _ = try await ExtensionCompiler.compileSingleFile(
                sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
            )
            Issue.record("Expected compilation to throw")
        } catch let error as ExtensionLoadError {
            if case .compilationError(_, let msg) = error {
                #expect(msg.contains("error:"), "Should contain swiftc error output, got: \(msg)")
            } else {
                Issue.record("Expected .compilationError, got \(error)")
            }
        }
    }
}

// MARK: - ExtensionDylibLoader Tests

@Test func loaderLoadsCompiledExtension() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        let hook = try ExtensionDylibLoader.loadAndInitialize(
            dylibPath: dylibPath,
            extensionPath: source,
            eventBus: eventBus,
            cwd: cacheDir
        )

        #expect(hook.path == source)
        // hello-extension.swift registers a "session_start" handler and a "hello" command
        #expect(hook.handlers["session_start"] != nil, "Should have session_start handler")
        #expect(hook.handlers["session_start"]?.count == 1)
        #expect(hook.commands["hello"] != nil, "Should have hello command")
        #expect(hook.commands["hello"]?.description == "Say hello from extension")
    }
}

@Test func loaderCapturesMultipleHandlersAndCommands() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("event-counter.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        let hook = try ExtensionDylibLoader.loadAndInitialize(
            dylibPath: dylibPath,
            extensionPath: source,
            eventBus: eventBus,
            cwd: cacheDir
        )

        // event-counter.swift registers handlers for session_start, agent_start, agent_end
        #expect(hook.handlers["session_start"] != nil)
        #expect(hook.handlers["agent_start"] != nil)
        #expect(hook.handlers["agent_end"] != nil)
        // And two commands: count, reset
        #expect(hook.commands["count"] != nil)
        #expect(hook.commands["reset"] != nil)
    }
}

@Test func loaderFailsOnMissingEntryPoint() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("no-entry-point.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        do {
            _ = try ExtensionDylibLoader.loadAndInitialize(
                dylibPath: dylibPath,
                extensionPath: source,
                eventBus: eventBus,
                cwd: cacheDir
            )
            Issue.record("Expected loading to throw due to missing piExtensionMain")
        } catch let error as ExtensionLoadError {
            if case .loadError(_, let msg) = error {
                #expect(msg.contains("piExtensionMain"), "Error should mention missing symbol, got: \(msg)")
            } else {
                Issue.record("Expected .loadError, got \(error)")
            }
        }
    }
}

// MARK: - ExtensionLoader Integration Tests

@Test func extensionLoaderDiscoversFindSwiftFiles() {
    let fixtureDir = URL(fileURLWithPath: fixturesRoot()).appendingPathComponent("extensions").path
    let discovered = ExtensionLoader.discover(in: fixtureDir)

    let names = discovered.map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(names.contains("hello-extension.swift"))
    #expect(names.contains("event-counter.swift"))
    #expect(names.contains("bad-syntax.swift"))
    #expect(names.contains("no-entry-point.swift"))
}

@Test func extensionLoaderDiscoverSkipsHiddenFiles() async throws {
    try await withTempDir { tempDir in
        let extDir = (tempDir as NSString).appendingPathComponent("extensions")
        try FileManager.default.createDirectory(atPath: extDir, withIntermediateDirectories: true)

        // Create a visible and hidden file
        try "visible".write(toFile: (extDir as NSString).appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try "hidden".write(toFile: (extDir as NSString).appendingPathComponent(".hidden.swift"), atomically: true, encoding: .utf8)

        let discovered = ExtensionLoader.discover(in: extDir)
        let names = discovered.map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(names.contains("visible.swift"))
        #expect(!names.contains(".hidden.swift"))
    }
}

@Test func extensionLoaderDiscoverReturnsEmptyForMissingDir() {
    let discovered = ExtensionLoader.discover(in: "/nonexistent/path/that/does/not/exist")
    #expect(discovered.isEmpty)
}

@Test func extensionLoaderFullPipelineLoadsExtension() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.error == nil, "Should load without error, got: \(String(describing: result.error))")
        #expect(result.hook != nil)
        #expect(result.hook?.commands["hello"] != nil)
        #expect(result.hook?.handlers["session_start"]?.count == 1)
    }
}

@Test func extensionLoaderReportsFileNotFound() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let result = await ExtensionLoader.load(
            "/nonexistent/path.swift",
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hook == nil)
        #expect(result.error != nil)
        if case .fileNotFound = result.error {
            // expected
        } else {
            Issue.record("Expected .fileNotFound, got \(String(describing: result.error))")
        }
    }
}

@Test func extensionLoaderReportsCompilationError() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("bad-syntax.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hook == nil)
        #expect(result.error != nil)
        if case .compilationError = result.error {
            // expected
        } else {
            Issue.record("Expected .compilationError, got \(String(describing: result.error))")
        }
    }
}

@Test func loadMultipleExtensions() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let paths = [
            extensionFixture("hello-extension.swift"),
            extensionFixture("event-counter.swift"),
        ]

        let result = await loadExtensions(
            paths,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.errors.isEmpty, "No errors expected, got: \(result.errors)")
        #expect(result.hooks.count == 2)

        // Verify hooks from both extensions are present
        let allCommands = result.hooks.flatMap { $0.commands.keys }
        #expect(allCommands.contains("hello"))
        #expect(allCommands.contains("count"))
        #expect(allCommands.contains("reset"))
    }
}

@Test func loadMixOfGoodAndBadExtensions() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let paths = [
            extensionFixture("hello-extension.swift"),
            extensionFixture("bad-syntax.swift"),
            extensionFixture("event-counter.swift"),
        ]

        let result = await loadExtensions(
            paths,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hooks.count == 2, "Two good extensions should load")
        #expect(result.errors.count == 1, "One bad extension should fail")
    }
}

// MARK: - HookRunner Integration

@Test func extensionHooksWorkWithHookRunner() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        guard let hook = result.hook else {
            Issue.record("Extension should load successfully")
            return
        }

        let sessionManager = SessionManager.inMemory()
        let authStorage = AuthStorage(":memory:")
        let modelRegistry = ModelRegistry(authStorage)

        let runner = HookRunner([hook], cacheDir, sessionManager, modelRegistry)
        runner.initialize(getModel: { nil }, hasUI: false)

        // Verify the command is accessible via the runner
        let command = runner.getCommand("hello")
        #expect(command != nil, "hello command should be registered in HookRunner")
        #expect(command?.description == "Say hello from extension")
    }
}
