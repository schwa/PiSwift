import Foundation
import PiSwiftAgent

public typealias Tool = AgentTool

public enum ToolName: String, CaseIterable, Sendable {
    case read
    case bash
    case edit
    case write
    case grep
    case find
    case ls
}

public let codingTools: [Tool] = [readTool, bashTool, editTool, writeTool]
public let readOnlyTools: [Tool] = [readTool, grepTool, findTool, lsTool]

public let allTools: [ToolName: Tool] = [
    .read: readTool,
    .bash: bashTool,
    .edit: editTool,
    .write: writeTool,
    .grep: grepTool,
    .find: findTool,
    .ls: lsTool,
]

public struct ToolsOptions: Sendable {
    public var read: ReadToolOptions?

    public init(read: ReadToolOptions? = nil) {
        self.read = read
    }
}

public func createCodingTools(cwd: String) -> [Tool] {
    createCodingTools(cwd: cwd, options: nil)
}

public func createCodingTools(cwd: String, options: ToolsOptions?) -> [Tool] {
    [createReadTool(cwd: cwd, options: options?.read), createBashTool(cwd: cwd), createEditTool(cwd: cwd), createWriteTool(cwd: cwd)]
}

public func createReadOnlyTools(cwd: String) -> [Tool] {
    createReadOnlyTools(cwd: cwd, options: nil)
}

public func createReadOnlyTools(cwd: String, options: ToolsOptions?) -> [Tool] {
    [createReadTool(cwd: cwd, options: options?.read), createGrepTool(cwd: cwd), createFindTool(cwd: cwd), createLsTool(cwd: cwd)]
}

public func createAllTools(cwd: String) -> [ToolName: Tool] {
    createAllTools(cwd: cwd, options: nil)
}

public func createAllTools(cwd: String, options: ToolsOptions?) -> [ToolName: Tool] {
    [
        .read: createReadTool(cwd: cwd, options: options?.read),
        .bash: createBashTool(cwd: cwd),
        .edit: createEditTool(cwd: cwd),
        .write: createWriteTool(cwd: cwd),
        .grep: createGrepTool(cwd: cwd),
        .find: createFindTool(cwd: cwd),
        .ls: createLsTool(cwd: cwd),
    ]
}
