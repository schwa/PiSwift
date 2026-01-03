import Testing
import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

@Test func sessionManagerLabelsSetAndGet() throws {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))

    #expect(session.getLabel(msgId) == nil)

    let labelId = try session.appendLabelChange(msgId, "checkpoint")
    #expect(session.getLabel(msgId) == "checkpoint")

    let entries = session.getEntries()
    let labelEntry = entries.first { entry in
        if case .label = entry { return true }
        return false
    }
    if case .label(let label) = labelEntry {
        #expect(label.id == labelId)
        #expect(label.targetId == msgId)
        #expect(label.label == "checkpoint")
    } else {
        #expect(Bool(false), "Expected label entry")
    }
}

@Test func sessionManagerLabelsClear() throws {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))

    _ = try session.appendLabelChange(msgId, "checkpoint")
    #expect(session.getLabel(msgId) == "checkpoint")

    _ = try session.appendLabelChange(msgId, nil)
    #expect(session.getLabel(msgId) == nil)
}

@Test func sessionManagerLabelsLastWins() throws {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))

    _ = try session.appendLabelChange(msgId, "first")
    _ = try session.appendLabelChange(msgId, "second")
    _ = try session.appendLabelChange(msgId, "third")

    #expect(session.getLabel(msgId) == "third")
}

@Test func sessionManagerLabelsInTree() throws {
    let session = SessionManager.inMemory()
    let msg1Id = session.appendMessage(userMsg("hello", timestamp: 1))
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "hi"))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop,
        timestamp: 2
    )
    let msg2Id = session.appendMessage(.assistant(assistant))

    _ = try session.appendLabelChange(msg1Id, "start")
    _ = try session.appendLabelChange(msg2Id, "response")

    let tree = session.getTree()
    let msg1Node = tree.first { $0.entry.id == msg1Id }
    #expect(msg1Node?.label == "start")

    let msg2Node = msg1Node?.children.first { $0.entry.id == msg2Id }
    #expect(msg2Node?.label == "response")
}

@Test func sessionManagerLabelsPreservedInBranch() throws {
    let session = SessionManager.inMemory()
    let msg1Id = session.appendMessage(userMsg("hello", timestamp: 1))
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "hi"))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop,
        timestamp: 2
    )
    let msg2Id = session.appendMessage(.assistant(assistant))

    _ = try session.appendLabelChange(msg1Id, "important")
    _ = try session.appendLabelChange(msg2Id, "also-important")

    _ = session.createBranchedSession(msg2Id)

    #expect(session.getLabel(msg1Id) == "important")
    #expect(session.getLabel(msg2Id) == "also-important")

    let entries = session.getEntries()
    let labelEntries = entries.compactMap { entry -> LabelEntry? in
        if case .label(let label) = entry { return label }
        return nil
    }
    #expect(labelEntries.count == 2)
}

@Test func sessionManagerLabelsNotOnPathDropped() throws {
    let session = SessionManager.inMemory()
    let msg1Id = session.appendMessage(userMsg("hello", timestamp: 1))
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "hi"))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop,
        timestamp: 2
    )
    let msg2Id = session.appendMessage(.assistant(assistant))
    let msg3Id = session.appendMessage(userMsg("followup", timestamp: 3))

    _ = try session.appendLabelChange(msg1Id, "first")
    _ = try session.appendLabelChange(msg2Id, "second")
    _ = try session.appendLabelChange(msg3Id, "third")

    _ = session.createBranchedSession(msg2Id)

    #expect(session.getLabel(msg1Id) == "first")
    #expect(session.getLabel(msg2Id) == "second")
    #expect(session.getLabel(msg3Id) == nil)
}

@Test func sessionManagerLabelsExcludedFromContext() throws {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello", timestamp: 1))
    _ = try session.appendLabelChange(msgId, "checkpoint")

    let ctx = session.buildSessionContext()
    #expect(ctx.messages.count == 1)
    #expect(ctx.messages.first?.role == "user")
}

@Test func sessionManagerLabelMissingEntryThrows() {
    let session = SessionManager.inMemory()
    do {
        _ = try session.appendLabelChange("non-existent", "label")
        #expect(Bool(false), "Expected error")
    } catch {
        #expect(error.localizedDescription.contains("Entry non-existent not found"))
    }
}
