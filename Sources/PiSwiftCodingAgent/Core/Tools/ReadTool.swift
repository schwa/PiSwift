import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct ReadToolDetails: Sendable {
    public var truncation: TruncationResult?
}

public func createReadTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "read",
        name: "read",
        description: "Read the contents of a file. Supports text files and images (jpg, png, gif, webp).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to read (relative or absolute)"],
                "offset": ["type": "number", "description": "Line number to start reading from (1-indexed)"],
                "limit": ["type": "number", "description": "Maximum number of lines to read"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw NSError(domain: "ReadTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation aborted"])
        }
        guard let path = params["path"]?.value as? String else {
            throw NSError(domain: "ReadTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing path"])
        }
        let offset = intValue(params["offset"])
        let limit = intValue(params["limit"])

        let absolutePath = resolveReadPath(path, cwd: cwd)

        if !FileManager.default.isReadableFile(atPath: absolutePath) {
            throw NSError(domain: "ReadTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }

        if let mimeType = detectSupportedImageMimeType(fromFile: absolutePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            let base64 = data.base64EncodedString()
            let content: [ContentBlock] = [
                .text(TextContent(text: "Read image file [\(mimeType)]")),
                .image(ImageContent(data: base64, mimeType: mimeType)),
            ]
            return AgentToolResult(content: content)
        }

        let textContent = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let allLines = textContent.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let totalLines = allLines.count

        let startLine = max(0, (offset ?? 1) - 1)
        let startLineDisplay = startLine + 1

        if startLine >= totalLines {
            throw NSError(
                domain: "ReadTool",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Offset \(offset ?? 0) is beyond end of file (\(totalLines) lines total)"]
            )
        }

        let selectedContent: String
        let userLimitedLines: Int?
        if let limit {
            let endLine = min(startLine + limit, totalLines)
            selectedContent = allLines[startLine..<endLine].joined(separator: "\n")
            userLimitedLines = endLine - startLine
        } else {
            selectedContent = allLines[startLine...].joined(separator: "\n")
            userLimitedLines = nil
        }

        let truncation = truncateHead(selectedContent)
        var details: AnyCodable? = nil
        var outputText: String

        if truncation.firstLineExceedsLimit {
            let firstLine = allLines[startLine]
            let firstLineSize = formatSize(firstLine.utf8.count)
            outputText = "[Line \(startLineDisplay) is \(firstLineSize), exceeds \(formatSize(DEFAULT_MAX_BYTES)) limit. Use bash: sed -n '\(startLineDisplay)p' \(path) | head -c \(DEFAULT_MAX_BYTES)]"
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if truncation.truncated {
            let endLineDisplay = startLineDisplay + truncation.outputLines - 1
            let nextOffset = endLineDisplay + 1
            outputText = truncation.content
            if truncation.truncatedBy == "lines" {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalLines). Use offset=\(nextOffset) to continue]"
            } else {
                outputText += "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalLines) (\(formatSize(DEFAULT_MAX_BYTES)) limit). Use offset=\(nextOffset) to continue]"
            }
            details = AnyCodable(["truncation": truncationToAnyCodable(truncation).value])
        } else if let userLimitedLines, startLine + userLimitedLines < totalLines {
            let remaining = totalLines - (startLine + userLimitedLines)
            let nextOffset = startLine + userLimitedLines + 1
            outputText = truncation.content
            outputText += "\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue]"
        } else {
            outputText = truncation.content
        }

        return AgentToolResult(content: [.text(TextContent(text: outputText))], details: details)
    }
}

public let readTool = createReadTool(cwd: FileManager.default.currentDirectoryPath)
