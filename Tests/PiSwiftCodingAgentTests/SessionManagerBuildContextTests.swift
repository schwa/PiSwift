import Testing
import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

private func msg(id: String, parentId: String?, role: String, text: String) -> SessionMessageEntry {
    let timestamp = "2025-01-01T00:00:00Z"
    if role == "user" {
        return SessionMessageEntry(id: id, parentId: parentId, timestamp: timestamp, message: userMsg(text))
    }
    let usage = Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2)
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-test",
        usage: usage,
        stopReason: .stop,
        timestamp: 1
    )
    return SessionMessageEntry(id: id, parentId: parentId, timestamp: timestamp, message: .assistant(assistant))
}

private func compactionEntry(id: String, parentId: String?, summary: String, firstKeptEntryId: String) -> CompactionEntry {
    CompactionEntry(
        id: id,
        parentId: parentId,
        timestamp: "2025-01-01T00:00:00Z",
        summary: summary,
        firstKeptEntryId: firstKeptEntryId,
        tokensBefore: 1000,
        details: nil,
        fromHook: nil
    )
}

private func branchSummaryEntry(id: String, parentId: String?, summary: String, fromId: String) -> BranchSummaryEntry {
    BranchSummaryEntry(
        id: id,
        parentId: parentId,
        timestamp: "2025-01-01T00:00:00Z",
        fromId: fromId,
        summary: summary,
        details: nil,
        fromHook: nil
    )
}

private func thinkingLevelEntry(id: String, parentId: String?, level: String) -> ThinkingLevelChangeEntry {
    ThinkingLevelChangeEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", thinkingLevel: level)
}

private func modelChangeEntry(id: String, parentId: String?, provider: String, modelId: String) -> ModelChangeEntry {
    ModelChangeEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", provider: provider, modelId: modelId)
}

@Test func buildSessionContextEmpty() {
    let ctx = buildSessionContext([])
    #expect(ctx.messages.isEmpty)
    #expect(ctx.thinkingLevel == "off")
    #expect(ctx.model == nil)
}

@Test func buildSessionContextSimpleConversation() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "hello")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "hi there")),
        .message(msg(id: "3", parentId: "2", role: "user", text: "how are you")),
        .message(msg(id: "4", parentId: "3", role: "assistant", text: "great")),
    ]
    let ctx = buildSessionContext(entries)
    #expect(ctx.messages.count == 4)
    #expect(ctx.messages.map(\.role) == ["user", "assistant", "user", "assistant"])
}

@Test func buildSessionContextThinkingLevel() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "hello")),
        .thinkingLevel(thinkingLevelEntry(id: "2", parentId: "1", level: "high")),
        .message(msg(id: "3", parentId: "2", role: "assistant", text: "thinking hard")),
    ]
    let ctx = buildSessionContext(entries)
    #expect(ctx.thinkingLevel == "high")
    #expect(ctx.messages.count == 2)
}

@Test func buildSessionContextModelTracking() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "hello")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "hi")),
    ]
    let ctx = buildSessionContext(entries)
    #expect(ctx.model?.provider == "anthropic")
    #expect(ctx.model?.modelId == "claude-test")

    let entries2: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "hello")),
        .modelChange(modelChangeEntry(id: "2", parentId: "1", provider: "openai", modelId: "gpt-4")),
        .message(msg(id: "3", parentId: "2", role: "assistant", text: "hi")),
    ]
    let ctx2 = buildSessionContext(entries2)
    #expect(ctx2.model?.provider == "anthropic")
    #expect(ctx2.model?.modelId == "claude-test")
}

@Test func buildSessionContextWithCompaction() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "first")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "response1")),
        .message(msg(id: "3", parentId: "2", role: "user", text: "second")),
        .message(msg(id: "4", parentId: "3", role: "assistant", text: "response2")),
        .compaction(compactionEntry(id: "5", parentId: "4", summary: "Summary of first two turns", firstKeptEntryId: "3")),
        .message(msg(id: "6", parentId: "5", role: "user", text: "third")),
        .message(msg(id: "7", parentId: "6", role: "assistant", text: "response3")),
    ]
    let ctx = buildSessionContext(entries)
    #expect(ctx.messages.count == 5)
    if case .custom(let summary) = ctx.messages[0] {
        #expect(summary.role == "compactionSummary")
    } else {
        #expect(Bool(false), "Expected compaction summary")
    }
}

@Test func buildSessionContextMultipleCompactions() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "a")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "b")),
        .compaction(compactionEntry(id: "3", parentId: "2", summary: "First summary", firstKeptEntryId: "1")),
        .message(msg(id: "4", parentId: "3", role: "user", text: "c")),
        .message(msg(id: "5", parentId: "4", role: "assistant", text: "d")),
        .compaction(compactionEntry(id: "6", parentId: "5", summary: "Second summary", firstKeptEntryId: "4")),
        .message(msg(id: "7", parentId: "6", role: "user", text: "e")),
    ]
    let ctx = buildSessionContext(entries)
    #expect(ctx.messages.count == 4)
}

@Test func buildSessionContextBranches() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "start")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "response")),
        .message(msg(id: "3", parentId: "2", role: "user", text: "branch A")),
        .message(msg(id: "4", parentId: "2", role: "user", text: "branch B")),
    ]
    let ctxA = buildSessionContext(entries, "3")
    #expect(ctxA.messages.count == 3)
    let ctxB = buildSessionContext(entries, "4")
    #expect(ctxB.messages.count == 3)
}

@Test func buildSessionContextBranchSummary() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "start")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "response")),
        .message(msg(id: "3", parentId: "2", role: "user", text: "abandoned")),
        .branchSummary(branchSummaryEntry(id: "4", parentId: "2", summary: "Summary of abandoned work", fromId: "3")),
        .message(msg(id: "5", parentId: "4", role: "user", text: "new direction")),
    ]
    let ctx = buildSessionContext(entries, "5")
    #expect(ctx.messages.count == 4)
}

@Test func buildSessionContextComplexTree() {
    let entries: [SessionEntry] = [
        .message(msg(id: "1", parentId: nil, role: "user", text: "start")),
        .message(msg(id: "2", parentId: "1", role: "assistant", text: "r1")),
        .message(msg(id: "3", parentId: "2", role: "user", text: "q2")),
        .message(msg(id: "4", parentId: "3", role: "assistant", text: "r2")),
        .compaction(compactionEntry(id: "5", parentId: "4", summary: "Compacted history", firstKeptEntryId: "3")),
        .message(msg(id: "6", parentId: "5", role: "user", text: "q3")),
        .message(msg(id: "7", parentId: "6", role: "assistant", text: "r3")),
        .message(msg(id: "8", parentId: "3", role: "user", text: "wrong path")),
        .message(msg(id: "9", parentId: "8", role: "assistant", text: "wrong response")),
        .branchSummary(branchSummaryEntry(id: "10", parentId: "3", summary: "Tried wrong approach", fromId: "9")),
        .message(msg(id: "11", parentId: "10", role: "user", text: "better approach")),
    ]
    let ctxMain = buildSessionContext(entries, "7")
    #expect(ctxMain.messages.count == 5)
    let ctxBranch = buildSessionContext(entries, "11")
    #expect(ctxBranch.messages.count == 5)
}
