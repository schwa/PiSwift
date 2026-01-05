import Foundation
#if canImport(AppKit)
import AppKit
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
    #if os(Windows)
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
    #else
    try runClipboardCommand(command: "/usr/bin/pbcopy", args: [], input: text)
    #endif
}

public func clipboardHasImage() -> Bool {
#if canImport(AppKit)
    return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
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
#else
    return nil
#endif
}

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
