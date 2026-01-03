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

public func createCodingTools(cwd: String) -> [Tool] {
    [createReadTool(cwd: cwd), createBashTool(cwd: cwd), createEditTool(cwd: cwd), createWriteTool(cwd: cwd)]
}

public func createReadOnlyTools(cwd: String) -> [Tool] {
    [createReadTool(cwd: cwd), createGrepTool(cwd: cwd), createFindTool(cwd: cwd), createLsTool(cwd: cwd)]
}

public func createAllTools(cwd: String) -> [ToolName: Tool] {
    [
        .read: createReadTool(cwd: cwd),
        .bash: createBashTool(cwd: cwd),
        .edit: createEditTool(cwd: cwd),
        .write: createWriteTool(cwd: cwd),
        .grep: createGrepTool(cwd: cwd),
        .find: createFindTool(cwd: cwd),
        .ls: createLsTool(cwd: cwd),
    ]
}
