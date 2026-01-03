import Foundation
import PiSwiftAI
import PiSwiftAgent

public func createWriteTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "write",
        name: "write",
        description: "Write content to a file. Creates the file if it doesn't exist, overwrites if it does.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Path to the file to write (relative or absolute)"],
                "content": ["type": "string", "description": "Content to write to the file"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw NSError(domain: "WriteTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation aborted"])
        }
        guard let path = params["path"]?.value as? String else {
            throw NSError(domain: "WriteTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing path"])
        }
        let content = params["content"]?.value as? String ?? ""

        let absolutePath = resolveToCwd(path, cwd: cwd)
        let dir = URL(fileURLWithPath: absolutePath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)

        return AgentToolResult(content: [.text(TextContent(text: "Successfully wrote \(content.utf8.count) bytes to \(path)"))])
    }
}

public let writeTool = createWriteTool(cwd: FileManager.default.currentDirectoryPath)
