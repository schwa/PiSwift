import Foundation

/// Typealias so extension authors can use `ExtensionAPI` instead of `HookAPI`.
public typealias ExtensionAPI = HookAPI

/// The C-callable entry point signature extensions must export.
public typealias PiExtensionEntryPoint = @convention(c) (UnsafeMutableRawPointer) -> Void

/// Helper that hides the unsafe pointer dance from extension authors.
///
/// Usage inside an extension's `@_cdecl("piExtensionMain")`:
/// ```swift
/// @_cdecl("piExtensionMain")
/// public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
///     withExtensionAPI(raw) { pi in
///         pi.on("session_start") { ... }
///     }
/// }
/// ```
public func withExtensionAPI(_ raw: UnsafeMutableRawPointer, body: (ExtensionAPI) -> Void) {
    let api = Unmanaged<HookAPI>.fromOpaque(raw).takeUnretainedValue()
    body(api)
}
