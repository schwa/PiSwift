import Testing
import Foundation
@testable import PiMCPAdapter

@Suite("NPX Arg Parsing")
struct NpxArgParsingTests {
    @Test("Basic npx args: npx -y package-name")
    func basicNpxArgs() {
        let result = parseNpxArgs(["-y", "my-mcp-server"])
        #expect(result != nil)
        #expect(result?.packageSpec == "my-mcp-server")
        #expect(result?.extraArgs.isEmpty == true)
    }

    @Test("npx with --package flag")
    func npxWithPackageFlag() {
        let result = parseNpxArgs(["--package", "my-server", "--", "serve"])
        #expect(result?.packageSpec == "my-server")
        #expect(result?.extraArgs == ["serve"])
    }

    @Test("npx with --package= flag")
    func npxWithPackageEquals() {
        let result = parseNpxArgs(["--package=@scope/server@1.0.0"])
        #expect(result?.packageSpec == "@scope/server@1.0.0")
    }

    @Test("npx with extra args after package")
    func npxWithExtraArgs() {
        let result = parseNpxArgs(["-y", "server", "--port", "3000"])
        #expect(result?.packageSpec == "server")
        #expect(result?.extraArgs == ["--port", "3000"])
    }

    @Test("npx with -- separator")
    func npxWithSeparator() {
        let result = parseNpxArgs(["-y", "server", "--", "--port", "3000"])
        #expect(result?.packageSpec == "server")
        #expect(result?.extraArgs == ["--port", "3000"])
    }

    @Test("npx with no args returns nil")
    func npxNoArgs() {
        let result = parseNpxArgs([])
        #expect(result == nil)
    }

    @Test("npx with only flags returns nil")
    func npxOnlyFlags() {
        let result = parseNpxArgs(["-y", "--yes"])
        #expect(result == nil)
    }
}

@Suite("NPM Exec Arg Parsing")
struct NpmExecArgParsingTests {
    @Test("npm exec --package spec -- bin")
    func basicNpmExec() {
        let result = parseNpmExecArgs(["exec", "--yes", "--package", "my-server", "--", "my-server", "--flag"])
        #expect(result != nil)
        #expect(result?.packageSpec == "my-server")
        #expect(result?.binName == "my-server")
        #expect(result?.extraArgs == ["--flag"])
    }

    @Test("npm exec without exec verb returns nil")
    func noExecVerb() {
        let result = parseNpmExecArgs(["install", "my-server"])
        #expect(result == nil)
    }

    @Test("npm exec without package returns nil")
    func noPackage() {
        let result = parseNpmExecArgs(["exec", "--yes"])
        #expect(result == nil)
    }
}

@Suite("JS Detection")
struct JsDetectionTests {
    @Test("JavaScript file extensions")
    func jsExtensions() {
        #expect(isJavaScriptFile("/path/to/script.js") == true)
        #expect(isJavaScriptFile("/path/to/script.mjs") == true)
        #expect(isJavaScriptFile("/path/to/script.cjs") == true)
    }

    @Test("Non-JavaScript extensions")
    func nonJsExtensions() {
        #expect(isJavaScriptFile("/path/to/binary") == false)
        #expect(isJavaScriptFile("/path/to/script.py") == false)
        #expect(isJavaScriptFile("/path/to/script.ts") == false)
    }
}
