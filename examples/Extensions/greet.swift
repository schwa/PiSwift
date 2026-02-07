// greet.swift — Example PiSwift extension
//
// Drop this file into ~/.pi/agent/extensions/ and it will be compiled
// and loaded automatically when PiSwift starts.
//
// This extension:
// - Registers a /greet slash command
// - Listens to session_start to display a welcome notification
// - Adds a keyboard shortcut (Shift+G) to trigger a greeting

import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in

        // --- Event handler: welcome message on session start ---
        pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
            await ctx.ui.notify("Greet extension loaded!", .info)
            return nil
        }

        // --- Slash command: /greet [name] ---
        pi.registerCommand("greet", description: "Greet someone by name") { args, ctx in
            let name = args.trimmingCharacters(in: .whitespaces)
            let greeting = name.isEmpty ? "Hello, world!" : "Hello, \(name)!"
            await ctx.ui.notify(greeting, .info)
        }

        // --- Keyboard shortcut: Shift+G ---
        pi.registerShortcut(.init("shift+g"), description: "Quick greet") { ctx in
            await ctx.ui.notify("Hello from keyboard shortcut!", .info)
        }
    }
}
