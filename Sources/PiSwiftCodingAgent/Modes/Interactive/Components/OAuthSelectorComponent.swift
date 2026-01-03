import Foundation
import MiniTui

public final class OAuthSelectorComponent: Container {
    private let listContainer: Container
    private let onSelectCallback: (String) -> Void
    private let onCancelCallback: () -> Void

    public init(
        mode: String,
        authStorage: AuthStorage,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _ = mode
        _ = authStorage
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.listContainer = Container()
        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(TruncatedText(theme.bold("OAuth providers")))
        addChild(Spacer(1))

        addChild(listContainer)
        addChild(Spacer(1))
        addChild(DynamicBorder())

        updateList()
    }

    private func updateList() {
        listContainer.clear()
        listContainer.addChild(TruncatedText(theme.fg(.muted, "  OAuth providers not available in Swift port"), paddingX: 0, paddingY: 0))
    }

    public func handleInput(_ keyData: String) {
        if isEnter(keyData) {
            onCancelCallback()
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
            return
        }
        if isArrowUp(keyData) || isArrowDown(keyData) {
            return
        }
    }
}
