import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct HookContext: Sendable {
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var hasUI: Bool

    public init(sessionManager: SessionManager, modelRegistry: ModelRegistry, model: Model?, hasUI: Bool) {
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.hasUI = hasUI
    }
}

public protocol HookEvent: Sendable {
    var type: String { get }
}

public struct SessionBeforeCompactEvent: HookEvent, Sendable {
    public let type: String = "session_before_compact"
    public var preparation: CompactionPreparation
    public var branchEntries: [SessionEntry]
    public var customInstructions: String?
    public var signal: CancellationToken?

    public init(preparation: CompactionPreparation, branchEntries: [SessionEntry], customInstructions: String?, signal: CancellationToken?) {
        self.preparation = preparation
        self.branchEntries = branchEntries
        self.customInstructions = customInstructions
        self.signal = signal
    }
}

public struct SessionCompactEvent: HookEvent, Sendable {
    public let type: String = "session_compact"
    public var compactionEntry: CompactionEntry
    public var fromHook: Bool

    public init(compactionEntry: CompactionEntry, fromHook: Bool) {
        self.compactionEntry = compactionEntry
        self.fromHook = fromHook
    }
}

public struct SessionBeforeBranchEvent: HookEvent, Sendable {
    public let type: String = "session_before_branch"
    public var entryId: String

    public init(entryId: String) {
        self.entryId = entryId
    }
}

public struct SessionBranchEvent: HookEvent, Sendable {
    public let type: String = "session_branch"
    public var previousSessionFile: String?

    public init(previousSessionFile: String?) {
        self.previousSessionFile = previousSessionFile
    }
}

public struct SessionBeforeTreeEvent: HookEvent, Sendable {
    public let type: String = "session_before_tree"
    public var preparation: TreePreparation
    public var signal: CancellationToken?

    public init(preparation: TreePreparation, signal: CancellationToken?) {
        self.preparation = preparation
        self.signal = signal
    }
}

public struct SessionTreeEvent: HookEvent, Sendable {
    public let type: String = "session_tree"
    public var newLeafId: String?
    public var oldLeafId: String?
    public var summaryEntry: BranchSummaryEntry?
    public var fromHook: Bool?

    public init(newLeafId: String?, oldLeafId: String?, summaryEntry: BranchSummaryEntry?, fromHook: Bool?) {
        self.newLeafId = newLeafId
        self.oldLeafId = oldLeafId
        self.summaryEntry = summaryEntry
        self.fromHook = fromHook
    }
}

public struct SessionBeforeCompactResult: Sendable {
    public var cancel: Bool
    public var compaction: CompactionResult?

    public init(cancel: Bool = false, compaction: CompactionResult? = nil) {
        self.cancel = cancel
        self.compaction = compaction
    }
}

public struct SessionBeforeBranchResult: Sendable {
    public var cancel: Bool
    public var skipConversationRestore: Bool

    public init(cancel: Bool = false, skipConversationRestore: Bool = false) {
        self.cancel = cancel
        self.skipConversationRestore = skipConversationRestore
    }
}

public struct SessionBeforeTreeResult: Sendable {
    public var cancel: Bool
    public var summary: BranchSummaryResult?

    public init(cancel: Bool = false, summary: BranchSummaryResult? = nil) {
        self.cancel = cancel
        self.summary = summary
    }
}

public typealias HookHandler = @Sendable (_ event: HookEvent, _ context: HookContext) async throws -> Any?

public struct LoadedHook: Sendable {
    public var path: String
    public var resolvedPath: String
    public var handlers: [String: [HookHandler]]

    public init(path: String, resolvedPath: String, handlers: [String: [HookHandler]]) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.handlers = handlers
    }
}

public struct TreePreparation: Sendable {
    public var targetId: String
    public var oldLeafId: String?
    public var commonAncestorId: String?
    public var entriesToSummarize: [SessionEntry]
    public var userWantsSummary: Bool

    public init(targetId: String, oldLeafId: String?, commonAncestorId: String?, entriesToSummarize: [SessionEntry], userWantsSummary: Bool) {
        self.targetId = targetId
        self.oldLeafId = oldLeafId
        self.commonAncestorId = commonAncestorId
        self.entriesToSummarize = entriesToSummarize
        self.userWantsSummary = userWantsSummary
    }
}

public final class HookAPI: @unchecked Sendable {
    public private(set) var handlers: [String: [HookHandler]] = [:]

    public init() {}

    public func on<T: HookEvent>(_ type: String, _ handler: @Sendable @escaping (T, HookContext) async throws -> Any?) {
        let wrapper: HookHandler = { event, context in
            guard let typed = event as? T else { return nil }
            return try await handler(typed, context)
        }
        handlers[type, default: []].append(wrapper)
    }
}
