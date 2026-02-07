// All extension entry point types and helpers are defined in PiSwiftCodingAgent
// and re-exported via Exports.swift's `@_exported import PiSwiftCodingAgent`.
//
// Extension authors use `import PiExtensionSDK` which gives them access to:
//   - withExtensionAPI(_:body:)
//   - ExtensionAPI (typealias for HookAPI)
//   - PiExtensionEntryPoint
//   - All public PiSwiftCodingAgent types (event types, ToolDefinition, etc.)
