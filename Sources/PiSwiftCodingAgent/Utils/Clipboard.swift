import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public enum ClipboardError: Error, CustomStringConvertible {
    case missingTool(String)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .missingTool(let message):
            return message
        case .copyFailed(let message):
            return message
        }
    }
}

public func copyToClipboard(_ text: String) throws {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif os(Windows)
    try runClipboardCommand(command: "clip", args: [], input: text)
#elseif os(Linux)
    do {
        try runClipboardCommand(command: "xclip", args: ["-selection", "clipboard"], input: text)
    } catch {
        do {
            try runClipboardCommand(command: "xsel", args: ["--clipboard", "--input"], input: text)
        } catch {
            throw ClipboardError.missingTool("Failed to copy to clipboard. Install xclip or xsel.")
        }
    }
#elseif os(macOS)
    if NSApp != nil || NSClassFromString("NSApplication") != nil {
        NSPasteboard.general.setString(text, forType: .string)
    } else {
        try runClipboardCommand(command: "/usr/bin/pbcopy", args: [], input: text)
    }
#endif
}

public func clipboardHasImage() -> Bool {
#if canImport(AppKit)
    return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
#elseif canImport(UIKit)
    UIPasteboard.general.hasImages
#elseif os(Linux)
    return linuxClipboardHasImage()
#else
    return false
#endif
}

public func getClipboardImagePngData() -> Data? {
#if canImport(AppKit)
    guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
        return nil
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
#elseif canImport(UIKit)
    return UIPasteboard.general.image?.pngData()
#elseif os(Linux)
    return readLinuxClipboardImagePngData()
#else
    return nil
#endif
}

#if os(Linux)
private func linuxClipboardHasImage() -> Bool {
    readLinuxClipboardImagePngData() != nil
}

private func readLinuxClipboardImagePngData() -> Data? {
    if isWaylandSession() {
        if let data = runClipboardCommandBinary(command: "wl-paste", args: ["--type", "image/png"]) {
            return data
        }
    }

    return runClipboardCommandBinary(command: "xclip", args: ["-selection", "clipboard", "-t", "image/png", "-o"])
}

private func isWaylandSession() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if let wayland = env["WAYLAND_DISPLAY"], !wayland.isEmpty {
        return true
    }
    if let session = env["XDG_SESSION_TYPE"], session.lowercased() == "wayland" {
        return true
    }
    return false
}

private func runClipboardCommandBinary(command: String, args: [String]) -> Data? {
    let process = Process()
    if command.contains("/") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0, !data.isEmpty else { return nil }
    return data
}
#endif

#if !canImport(UIKit)
private func runClipboardCommand(command: String, args: [String], input: String) throws {
    let process = Process()
    if command.contains("/") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe

    do {
        try process.run()
    } catch {
        throw ClipboardError.copyFailed("Failed to launch clipboard command: \(command)")
    }

    if let data = input.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
    }
    try? stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        throw ClipboardError.copyFailed("Clipboard command failed: \(command)")
    }
}
#endif
