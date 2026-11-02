import AppKit

/// 带闭包的菜单项，省得每个菜单都写一个 @objc 方法
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String,
         key: String = "",
         modifiers: NSEvent.ModifierFlags = [],
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ActionMenuItem.fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @MainActor @objc private func fire() { handler() }
}

extension NSMenuItem {
    /// 灰色、不可点的说明文字
    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
