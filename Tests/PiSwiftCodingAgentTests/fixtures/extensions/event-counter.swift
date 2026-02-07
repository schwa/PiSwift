import PiExtensionSDK

/// A simple extension that registers handlers for multiple events.
/// Used as a test fixture to verify handler registration.
@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
            return nil
        }

        pi.on("agent_start") { (event: AgentStartEvent, ctx: HookContext) in
            return nil
        }

        pi.on("agent_end") { (event: AgentEndEvent, ctx: HookContext) in
            return nil
        }

        pi.registerCommand("count", description: "Show event counts") { args, ctx in
            await ctx.ui.notify("Event counter extension", .info)
        }

        pi.registerCommand("reset", description: "Reset counters") { args, ctx in
            // no-op in fixture
        }
    }
}
