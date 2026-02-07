import PiExtensionSDK

/// A Swift file that does NOT have piExtensionMain.
/// Used to test that dlsym fails gracefully.
public func someOtherFunction() {
    print("This extension has no entry point")
}
