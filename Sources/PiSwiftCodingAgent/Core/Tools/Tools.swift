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

private func shouldIncludeBashTool() -> Bool {
    #if canImport(UIKit)
    return BashExecutorRegistry.isAvailable()
    #else
    return true
    #endif
}

public var codingTools: [Tool] {
    var tools: [Tool] = [readTool]
    if shouldIncludeBashTool() {
        tools.append(bashTool)
    }
    tools.append(contentsOf: [editTool, writeTool])
    return tools
}

public var allTools: [ToolName: Tool] {
    var tools: [ToolName: Tool] = [
        .read: readTool,
        .edit: editTool,
        .write: writeTool,
        .grep: grepTool,
        .find: findTool,
        .ls: lsTool,
    ]
    if shouldIncludeBashTool() {
        tools[.bash] = bashTool
    }
    return tools
}
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

public func createCodingTools(cwd: String, options: ToolsOptions?, subagentContext: SubagentToolContext?) -> [Tool] {
    var tools: [Tool] = [createReadTool(cwd: cwd, options: options?.read)]
    if shouldIncludeBashTool() {
        tools.append(createBashTool(cwd: cwd))
    }
    tools.append(contentsOf: [
        createEditTool(cwd: cwd),
        createWriteTool(cwd: cwd),
    ])
    if let subagentContext {
        tools.append(createSubagentTool(subagentContext))
    }
    return tools
}
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
    var tools: [ToolName: Tool] = [
        .read: createReadTool(cwd: cwd, options: options?.read),
        .edit: createEditTool(cwd: cwd),
        .write: createWriteTool(cwd: cwd),
        .grep: createGrepTool(cwd: cwd),
        .find: createFindTool(cwd: cwd),
        .ls: createLsTool(cwd: cwd),
    ]
    if shouldIncludeBashTool() {
        tools[.bash] = createBashTool(cwd: cwd)
    }
    if let subagentContext {
        tools[.subagent] = createSubagentTool(subagentContext)
    }
    return tools
}

public func createAllTools(cwd: String, options: ToolsOptions?) -> [ToolName: Tool] {
    createAllTools(cwd: cwd, options: options, subagentContext: nil)
}
