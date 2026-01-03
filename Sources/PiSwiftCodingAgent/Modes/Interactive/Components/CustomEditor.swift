import Foundation
import MiniTui

public final class CustomEditor: Component {
    private let editor: Editor

    public var onEscape: (() -> Void)?
    public var onCtrlC: (() -> Void)?
    public var onCtrlD: (() -> Void)?
    public var onShiftTab: (() -> Void)?
    public var onCtrlP: (() -> Void)?
    public var onShiftCtrlP: (() -> Void)?
    public var onCtrlL: (() -> Void)?
    public var onCtrlO: (() -> Void)?
    public var onCtrlT: (() -> Void)?
    public var onCtrlG: (() -> Void)?
    public var onCtrlZ: (() -> Void)?
    public var onAltEnter: (() -> Void)?

    public var onSubmit: ((String) -> Void)? {
        get { editor.onSubmit }
        set { editor.onSubmit = newValue }
    }

    public var onChange: ((String) -> Void)? {
        get { editor.onChange }
        set { editor.onChange = newValue }
    }

    public var disableSubmit: Bool {
        get { editor.disableSubmit }
        set { editor.disableSubmit = newValue }
    }

    public var borderColor: @Sendable (String) -> String {
        get { editor.borderColor }
        set { editor.borderColor = newValue }
    }

    public init(theme: EditorTheme) {
        self.editor = Editor(theme: theme)
    }

    public func setText(_ text: String) {
        editor.setText(text)
    }

    public func getText() -> String {
        editor.getText()
    }

    public func addToHistory(_ text: String) {
        editor.addToHistory(text)
    }

    public func setAutocompleteProvider(_ provider: AutocompleteProvider) {
        editor.setAutocompleteProvider(provider)
    }

    public func isShowingAutocomplete() -> Bool {
        editor.isShowingAutocomplete()
    }

    public func invalidate() {
        editor.invalidate()
    }

    public func render(width: Int) -> [String] {
        editor.render(width: width)
    }

    public func handleInput(_ data: String) {
        if isAltEnter(data), let onAltEnter {
            onAltEnter()
            return
        }
        if isCtrlG(data), let onCtrlG {
            onCtrlG()
            return
        }
        if isCtrlZ(data), let onCtrlZ {
            onCtrlZ()
            return
        }
        if isCtrlT(data), let onCtrlT {
            onCtrlT()
            return
        }
        if isCtrlL(data), let onCtrlL {
            onCtrlL()
            return
        }
        if isCtrlO(data), let onCtrlO {
            onCtrlO()
            return
        }
        if isShiftCtrlP(data), let onShiftCtrlP {
            onShiftCtrlP()
            return
        }
        if isCtrlP(data), let onCtrlP {
            onCtrlP()
            return
        }
        if isShiftTab(data), let onShiftTab {
            onShiftTab()
            return
        }
        if isEscape(data), let onEscape, !editor.isShowingAutocomplete() {
            onEscape()
            return
        }
        if isCtrlC(data), let onCtrlC {
            onCtrlC()
            return
        }
        if isCtrlD(data) {
            if editor.getText().isEmpty, let onCtrlD {
                onCtrlD()
            }
            return
        }

        editor.handleInput(data)
    }
}
