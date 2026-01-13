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
    case subagent
}

#if canImport(UIKit)
public let codingTools: [Tool] = [readTool, editTool, writeTool]
public let allTools: [ToolName: Tool] = [
    .read: readTool,
    .edit: editTool,
    .write: writeTool,
    .grep: grepTool,
    .find: findTool,
    .ls: lsTool,
]
#else
public let codingTools: [Tool] = [readTool, bashTool, editTool, writeTool]
public let allTools: [ToolName: Tool] = [
    .read: readTool,
    .bash: bashTool,
    .edit: editTool,
    .write: writeTool,
    .grep: grepTool,
    .find: findTool,
    .ls: lsTool,
]
#endif
public let readOnlyTools: [Tool] = [readTool, grepTool, findTool, lsTool]

public struct ToolsOptions: Sendable {
    public var read: ReadToolOptions?

    public init(read: ReadToolOptions? = nil) {
        self.read = read
    }
}

public func createCodingTools(cwd: String) -> [Tool] {
    createCodingTools(cwd: cwd, options: nil)
}

#if canImport(UIKit)
public func createCodingTools(cwd: String, options: ToolsOptions?, subagentContext: SubagentToolContext?) -> [Tool] {
    var tools: [Tool] = [
        createReadTool(cwd: cwd, options: options?.read),
        createEditTool(cwd: cwd),
        createWriteTool(cwd: cwd),
    ]
    if let subagentContext {
        tools.append(createSubagentTool(subagentContext))
    }
    return tools
}
#else
public func createCodingTools(cwd: String, options: ToolsOptions?, subagentContext: SubagentToolContext?) -> [Tool] {
    var tools: [Tool] = [
        createReadTool(cwd: cwd, options: options?.read),
        createBashTool(cwd: cwd),
        createEditTool(cwd: cwd),
        createWriteTool(cwd: cwd),
    ]
    if let subagentContext {
        tools.append(createSubagentTool(subagentContext))
    }
    return tools
}
#endif
public func createCodingTools(cwd: String, options: ToolsOptions?) -> [Tool] {
    createCodingTools(cwd: cwd, options: options, subagentContext: nil)
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

public func createAllTools(cwd: String, options: ToolsOptions?, subagentContext: SubagentToolContext?) -> [ToolName: Tool] {
#if canImport(AppKit)
    let extra: [ToolName: Tool] = [.bash: createBashTool(cwd: cwd)]
#else
    let extra: [ToolName: Tool] = [:]
#endif
    var tools: [ToolName: Tool] = [
        .read: createReadTool(cwd: cwd, options: options?.read),
        .edit: createEditTool(cwd: cwd),
        .write: createWriteTool(cwd: cwd),
        .grep: createGrepTool(cwd: cwd),
        .find: createFindTool(cwd: cwd),
        .ls: createLsTool(cwd: cwd),
    ]
    if let subagentContext {
        tools[.subagent] = createSubagentTool(subagentContext)
    }
    for (k, v) in extra {
        tools[k] = v
    }
    return tools
}

public func createAllTools(cwd: String, options: ToolsOptions?) -> [ToolName: Tool] {
    createAllTools(cwd: cwd, options: options, subagentContext: nil)
}
