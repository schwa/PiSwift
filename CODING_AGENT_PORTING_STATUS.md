# Coding Agent Porting Status (JS -> Swift)

This document tracks parity between the JS module in `pi-mono/packages/coding-agent` and the Swift module under `PiSwift`.

## Ported (feature-complete or very close)
- Core tools: `pi-mono/packages/coding-agent/src/core/tools/*` -> `Sources/PiSwiftCodingAgent/Core/Tools/*`
- Compaction + branch summarization: `pi-mono/packages/coding-agent/src/core/compaction/*` -> `Sources/PiSwiftCodingAgent/Core/Compaction/*`
- Model resolver + registry: `pi-mono/packages/coding-agent/src/core/model-resolver.ts` -> `Sources/PiSwiftCodingAgent/Core/ModelResolver.swift`; `pi-mono/packages/coding-agent/src/core/model-registry.ts` -> `Sources/PiSwiftCodingAgent/Core/ModelRegistry.swift`
- Session manager: `pi-mono/packages/coding-agent/src/core/session-manager.ts` -> `Sources/PiSwiftCodingAgent/Core/SessionManager.swift`
- Agent session core (steer/followUp, concurrency guard): `pi-mono/packages/coding-agent/src/core/agent-session.ts` -> `Sources/PiSwiftCodingAgent/Core/AgentSession.swift`
- Settings, auth storage, bash executor, messages:
  - `pi-mono/packages/coding-agent/src/core/settings-manager.ts` -> `Sources/PiSwiftCodingAgent/Core/SettingsManager.swift`
  - `pi-mono/packages/coding-agent/src/core/auth-storage.ts` -> `Sources/PiSwiftCodingAgent/Core/AuthStorage.swift`
  - `pi-mono/packages/coding-agent/src/core/bash-executor.ts` -> `Sources/PiSwiftCodingAgent/Core/BashExecutor.swift`
  - `pi-mono/packages/coding-agent/src/core/messages.ts` -> `Sources/PiSwiftCodingAgent/Core/Messages.swift`
- Skills + system prompt stack: `pi-mono/packages/coding-agent/src/core/skills.ts` + `system-prompt.ts` -> `Sources/PiSwiftCodingAgent/Core/Skills.swift` + `Sources/PiSwiftCodingAgent/Core/SystemPrompt.swift`
- Slash commands + @file expansion: `pi-mono/packages/coding-agent/src/core/slash-commands.ts` -> `Sources/PiSwiftCodingAgent/Core/SlashCommands.swift`
- CLI helpers: `pi-mono/packages/coding-agent/src/cli/file-processor.ts`, `list-models.ts`, `session-picker.ts` -> `Sources/PiSwiftCodingAgent/CLI/*`
- Utilities: `pi-mono/packages/coding-agent/src/utils/fuzzy.ts` -> `Sources/PiSwiftCodingAgent/Utils/Fuzzy.swift`; `pi-mono/packages/coding-agent/src/utils/mime.ts` -> `Sources/PiSwiftCodingAgent/Utils/Mime.swift`; glob handling in `Sources/PiSwiftCodingAgent/Utils/Glob.swift`; tools manager in `Sources/PiSwiftCodingAgent/Utils/ToolsManager.swift`
- Shell/clipboard/changelog utils + timings/migrations: `pi-mono/packages/coding-agent/src/utils/{shell,clipboard,changelog}.ts` + `src/core/timings.ts` + `src/migrations.ts` -> `Sources/PiSwiftCodingAgent/Utils/{Shell,Clipboard,Changelog}.swift`, `Sources/PiSwiftCodingAgent/Core/Timings.swift`, `Sources/PiSwiftCodingAgent/Migrations.swift`
- Exec helper: `pi-mono/packages/coding-agent/src/core/exec.ts` -> `Sources/PiSwiftCodingAgent/Core/Exec.swift`
- Interactive mode + components (MiniTui): `pi-mono/packages/coding-agent/src/modes/interactive/*` -> `Sources/PiSwiftCodingAgent/Modes/Interactive/*`
- Theme loading + JSON themes: `pi-mono/packages/coding-agent/src/modes/interactive/theme/*` -> `Sources/PiSwiftCodingAgent/Modes/Interactive/Theme.swift` + `Sources/PiSwiftCodingAgent/Resources/theme/*`
- CLI orchestration + TUI: `pi-mono/packages/coding-agent/src/main.ts` + `cli.ts` -> `Sources/PiSwiftCodingAgentCLI/main.swift` (interactive mode wiring)
- SDK: `pi-mono/packages/coding-agent/src/core/sdk.ts` -> `Sources/PiSwiftCodingAgent/Core/SDK.swift` (custom tools discovery + wrapping, hook discovery supports bundles)
- Hook loader + tool wrapper: `pi-mono/packages/coding-agent/src/core/hooks/loader.ts`, `pi-mono/packages/coding-agent/src/core/hooks/tool-wrapper.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookLoader.swift`, `Sources/PiSwiftCodingAgent/Core/Hooks/ToolWrapper.swift` (bundle-based hooks)
- Hook runtime: `pi-mono/packages/coding-agent/src/core/hooks/runner.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookRunner.swift` (context/before_agent_start/session/agent/turn events)
- Custom tools pipeline: `pi-mono/packages/coding-agent/src/core/custom-tools/*` -> `Sources/PiSwiftCodingAgent/Core/CustomTools/*` + CLI/TUI wiring
- RPC mode: `pi-mono/packages/coding-agent/src/modes/rpc/*` -> `Sources/PiSwiftCodingAgent/Modes/RpcMode.swift` (JSON protocol + hook UI + command handling)

## Partial / stubs (implemented but missing JS behavior)
- Print mode: `pi-mono/packages/coding-agent/src/modes/print-mode.ts` -> `Sources/PiSwiftCodingAgent/Modes/PrintMode.swift` (JSON event stream + assistant-only text output, no rich formatting)
- Export HTML: `pi-mono/packages/coding-agent/src/core/export-html/*` -> `Sources/PiSwiftCodingAgent/Core/ExportHtml.swift` (simple HTML stub)
- CLI args parsing: `pi-mono/packages/coding-agent/src/cli/args.ts` -> `Sources/PiSwiftCodingAgent/CLI/Args.swift` (parsing exists; wiring is minimal)

## Not required
- Config + package detection/versioning: `pi-mono/packages/coding-agent/src/config.ts` -> `Sources/PiSwiftCodingAgent/Config.swift` (no package.json-driven name/version, bun/tsx detection, theme/export path resolution logic)

## Task Queue (next in order)
- [x] Hook UI context + commands: expose `HookUIContext` in interactive mode (select/confirm/input/custom/editor/status), register slash commands, and route hook message renderers.
- [x] Wire hook discovery into CLI runtime (load bundles from hook paths; surface load errors).
- [x] Custom tools pipeline: loader + wrapping tools with `CustomToolContext` and UI context bridge.
- [x] RPC mode: JSON protocol support + hook UI + command handling.
- [ ] Export HTML: parity with JS formatting + assets.
- [ ] Print mode: richer formatting parity (colors/format) and output flushing.
- [ ] CLI args: finish wiring for remaining flags and behaviors.
