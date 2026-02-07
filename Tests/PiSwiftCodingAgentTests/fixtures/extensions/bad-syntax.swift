import PiExtensionSDK

/// Intentionally broken Swift file to test compilation error handling.
@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    this is not valid swift code !!!
}
