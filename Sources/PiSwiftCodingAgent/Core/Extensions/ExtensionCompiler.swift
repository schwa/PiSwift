import Foundation
import CryptoKit

/// Compiles `.swift` extension files and SPM package directories into loadable dylibs.
public struct ExtensionCompiler {

    /// Paths to the PiExtensionSDK module and library used during compilation.
    public struct SDKPaths: Sendable {
        /// Directory containing `PiExtensionSDK.swiftmodule`
        public let modulePath: String
        /// Directory containing `libPiExtensionSDK.dylib`
        public let libPath: String

        public init(modulePath: String, libPath: String) {
            self.modulePath = modulePath
            self.libPath = libPath
        }
    }

    // MARK: - Public API

    /// Compile a single `.swift` file to a dylib, using the cache when possible.
    /// - Returns: Path to the compiled `.dylib`.
    public static func compileSingleFile(
        sourcePath: String,
        cacheDir: String,
        sdkPaths: SDKPaths
    ) async throws -> String {
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let sourceHash = sha256(sourceData)

        // Include SDK dylib hash so cache invalidates when PiSwift itself changes.
        let sdkDylibPath = (sdkPaths.libPath as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        let sdkHash: String
        if let sdkData = try? Data(contentsOf: URL(fileURLWithPath: sdkDylibPath)) {
            sdkHash = sha256(sdkData)
        } else {
            sdkHash = "no-sdk"
        }

        let cacheKey = sha256(Data((sourceHash + sdkHash).utf8))
        let dylibName = "\(cacheKey).dylib"
        let dylibPath = (cacheDir as NSString).appendingPathComponent(dylibName)

        if FileManager.default.fileExists(atPath: dylibPath) {
            return dylibPath
        }

        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        let baseName = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let moduleName = "PiExtension_\(sanitizeModuleName(baseName))"

        // Use -undefined dynamic_lookup instead of -lPiExtensionSDK so the
        // compiled extension doesn't carry a hard dependency on the SDK dylib.
        // Symbols are resolved at runtime from the host process, which already
        // has PiSwiftCodingAgent loaded.  This avoids duplicate ObjC class
        // registration when the extension is dlopen'd into a process that also
        // statically links the same modules.
        let args = [
            "swiftc",
            "-emit-library",
            "-o", dylibPath,
            "-module-name", moduleName,
            "-parse-as-library",
            "-swift-version", "6",
            "-I", sdkPaths.modulePath,
            "-Xlinker", "-undefined",
            "-Xlinker", "dynamic_lookup",
            sourcePath,
        ]

        let result = try await runProcess(args)
        guard result.exitCode == 0 else {
            // Clean up partial output
            try? FileManager.default.removeItem(atPath: dylibPath)
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtensionLoadError.compilationError(
                path: sourcePath,
                error: stderr.isEmpty ? "swiftc exited with code \(result.exitCode)" : stderr
            )
        }

        return dylibPath
    }

    /// Build an SPM package directory and return the path to the produced dylib.
    /// - Returns: Path to the built `.dylib`.
    public static func buildPackageDirectory(
        packageDir: String,
        cacheDir: String
    ) async throws -> String {
        let args = [
            "swift", "build",
            "--package-path", packageDir,
            "--configuration", "release",
        ]

        let result = try await runProcess(args)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtensionLoadError.packageLoadError(
                path: packageDir,
                error: stderr.isEmpty ? "swift build exited with code \(result.exitCode)" : stderr
            )
        }

        // Find the built dylib in .build/release/
        let releaseDir = (packageDir as NSString).appendingPathComponent(".build/release")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: releaseDir) else {
            throw ExtensionLoadError.packageLoadError(path: packageDir, error: "No build output found in .build/release/")
        }

        if let dylib = entries.first(where: { $0.hasSuffix(".dylib") }) {
            return (releaseDir as NSString).appendingPathComponent(dylib)
        }

        throw ExtensionLoadError.packageLoadError(path: packageDir, error: "No .dylib found in build output")
    }

    /// Resolve the SDK module and library paths for compiling extensions.
    public static func resolveSDKPaths() -> SDKPaths? {
        // 1. Explicit override via environment variable
        if let sdkDir = ProcessInfo.processInfo.environment["PI_EXTENSION_SDK_PATH"],
           !sdkDir.isEmpty,
           FileManager.default.fileExists(atPath: sdkDir) {
            return SDKPaths(modulePath: sdkDir, libPath: sdkDir)
        }

        // 2. ~/.pi/agent/sdk/
        let agentSDK = (getAgentDir() as NSString).appendingPathComponent("sdk")
        if FileManager.default.fileExists(atPath: (agentSDK as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")) {
            return SDKPaths(modulePath: agentSDK, libPath: agentSDK)
        }

        // 3. Relative to current executable (for development / installed builds)
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let execDir = execURL.path
        if FileManager.default.fileExists(atPath: (execDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")) {
            // Check for Modules subdirectory (SPM layout) or same directory (installed layout)
            let modulesSubdir = (execDir as NSString).appendingPathComponent("Modules")
            let moduleDir = FileManager.default.fileExists(atPath: (modulesSubdir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule"))
                ? modulesSubdir : execDir
            return SDKPaths(modulePath: moduleDir, libPath: execDir)
        }

        // 4. SPM build artifacts (debug then release)
        for config in ["debug", "release"] {
            let buildDir = findSPMBuildDir(config: config)
            if let buildDir,
               FileManager.default.fileExists(atPath: (buildDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")) {
                let modulesDir = (buildDir as NSString).appendingPathComponent("Modules")
                let moduleDir = FileManager.default.fileExists(atPath: (modulesDir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule"))
                    ? modulesDir : buildDir
                return SDKPaths(modulePath: moduleDir, libPath: buildDir)
            }
        }

        return nil
    }

    // MARK: - Internal helpers

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeModuleName(_ name: String) -> String {
        var result = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "_" {
                result.append(ch)
            } else {
                result.append("_")
            }
        }
        if result.isEmpty || result.first!.isNumber {
            result = "_" + result
        }
        return result
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(_ args: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func findSPMBuildDir(config: String) -> String? {
        // Walk up from the executable to find a .build directory
        var dir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(".build/\(config)").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
