import Foundation
import MiniTui

public final class UserMessageComponent: Container {
    public init(text: String) {
        super.init()
        addChild(Spacer(1))
        let style = DefaultTextStyle(
            color: { theme.fg(.userMessageText, $0) },
            bgColor: { theme.bg(.userMessageBg, $0) }
        )
        addChild(Markdown(text, paddingX: 1, paddingY: 1, theme: getMarkdownTheme(), defaultTextStyle: style))
    }
}
