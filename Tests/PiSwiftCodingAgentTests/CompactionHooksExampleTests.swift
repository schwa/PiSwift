import Foundation
import Testing
import PiSwiftCodingAgent

private actor ValueBox<T> {
    private var value: T?

    func set(_ newValue: T) {
        value = newValue
    }

    func get() -> T? {
        value
    }
}

@Test func compactionHookExampleTypes() async throws {
    let api = HookAPI()
    let captured = ValueBox<SessionBeforeCompactEvent>()

    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _ctx: HookContext) in
        await captured.set(event)
        return SessionBeforeCompactResult(
            cancel: false,
            compaction: CompactionResult(
                summary: "Example summary",
                firstKeptEntryId: event.preparation.firstKeptEntryId,
                tokensBefore: event.preparation.tokensBefore,
                details: nil
            )
        )
    }

    #expect(api.handlers["session_before_compact"]?.count == 1)

    let handler = api.handlers["session_before_compact"]?.first
    let prep = CompactionPreparation(
        firstKeptEntryId: "id",
        messagesToSummarize: [],
        turnPrefixMessages: [],
        isSplitTurn: false,
        tokensBefore: 0,
        previousSummary: nil,
        fileOps: FileOperations(),
        settings: DEFAULT_COMPACTION_SETTINGS
    )
    let event = SessionBeforeCompactEvent(preparation: prep, branchEntries: [], customInstructions: nil, signal: nil)
    let ctx = HookContext(sessionManager: SessionManager.inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)

    _ = try await handler?(event, ctx)
    let capturedEvent = await captured.get()
    #expect(capturedEvent?.preparation.firstKeptEntryId == "id")
}

@Test func compactEventFieldsAvailable() async throws {
    let api = HookAPI()
    let didRun = ValueBox<Bool>()

    api.on("session_compact") { (event: SessionCompactEvent, _ctx: HookContext) in
        #expect(event.compactionEntry.type == "compaction")
        #expect(!event.compactionEntry.summary.isEmpty)
        #expect(event.compactionEntry.tokensBefore >= 0)
        #expect(event.fromHook == false)
        await didRun.set(true)
        return nil
    }

    let handler = api.handlers["session_compact"]?.first
    let entry = CompactionEntry(
        id: "compaction-id",
        parentId: nil,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        summary: "Summary",
        firstKeptEntryId: "first",
        tokensBefore: 1,
        details: nil,
        fromHook: false
    )
    let event = SessionCompactEvent(compactionEntry: entry, fromHook: false)
    let ctx = HookContext(sessionManager: SessionManager.inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)

    _ = try await handler?(event, ctx)
    #expect(await didRun.get() == true)
}
