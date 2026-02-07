import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
            return nil
        }

        pi.registerCommand("hello", description: "Say hello from extension") { args, ctx in
            await ctx.ui.notify("Hello from hello-extension!", .info)
        }
    }
}
