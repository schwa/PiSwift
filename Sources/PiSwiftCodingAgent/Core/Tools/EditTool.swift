import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct EditToolDetails: Sendable {
    public var diff: String
    public var firstChangedLine: Int?
}

public func createEditTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "edit",
        name: "edit",
        description: "Edit a file by replacing exact text. The oldText must match exactly (including whitespace).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to edit (relative or absolute)"],
                "oldText": ["type": "string", "description": "Exact text to find and replace"],
                "newText": ["type": "string", "description": "New text to replace the old text with"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw NSError(domain: "EditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation aborted"])
        }
        guard let path = params["path"]?.value as? String else {
            throw NSError(domain: "EditTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing path"])
        }
        let oldText = params["oldText"]?.value as? String ?? ""
        let newText = params["newText"]?.value as? String ?? ""

        let absolutePath = resolveToCwd(path, cwd: cwd)
        guard FileManager.default.isReadableFile(atPath: absolutePath),
              FileManager.default.isWritableFile(atPath: absolutePath) else {
            throw NSError(domain: "EditTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
        }

        let rawContent = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let stripped = stripBom(rawContent)
        let content = stripped.text
        let bom = stripped.bom

        let originalEnding = detectLineEnding(content)
        let normalizedContent = normalizeToLF(content)
        let normalizedOldText = normalizeToLF(oldText)
        let normalizedNewText = normalizeToLF(newText)

        guard normalizedContent.contains(normalizedOldText) else {
            throw NSError(
                domain: "EditTool",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."]
            )
        }

        let occurrences = normalizedContent.components(separatedBy: normalizedOldText).count - 1
        if occurrences > 1 {
            throw NSError(
                domain: "EditTool",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Found \(occurrences) occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."]
            )
        }

        guard let range = normalizedContent.range(of: normalizedOldText) else {
            throw NSError(domain: "EditTool", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not find the exact text in \(path)."])
        }

        let normalizedNewContent = normalizedContent.replacingCharacters(in: range, with: normalizedNewText)
        if normalizedContent == normalizedNewContent {
            throw NSError(
                domain: "EditTool",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No changes made to \(path). The replacement produced identical content."]
            )
        }

        let finalContent = bom + restoreLineEndings(normalizedNewContent, originalEnding)
        try finalContent.write(toFile: absolutePath, atomically: true, encoding: .utf8)

        let diffResult = generateDiffString(normalizedContent, normalizedNewContent)
        let firstChanged: Any = diffResult.firstChangedLine != nil ? diffResult.firstChangedLine! : NSNull()
        let details = AnyCodable([
            "diff": diffResult.diff,
            "firstChangedLine": firstChanged,
        ])

        return AgentToolResult(
            content: [.text(TextContent(text: "Successfully replaced text in \(path)."))],
            details: details
        )
    }
}

public let editTool = createEditTool(cwd: FileManager.default.currentDirectoryPath)
