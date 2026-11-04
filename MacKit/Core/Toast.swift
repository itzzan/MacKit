import AppKit

/// 屏幕下方一闪而过的小提示，不抢焦点、鼠标可以穿过去
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    /// action 不为空时提示条能点：点一下执行 action 并收起
    static func show(_ text: String, seconds: Double = 1.8, action: (@MainActor () -> Void)? = nil) {
        panel?.orderOut(nil)
        let p = makePanel(text, action: action)
        present(p)
        panel = p

        generation += 1
        let mine = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard mine == generation else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }
            guard mine == generation else { return }
            p.orderOut(nil)
            panel = nil
        }
    }

    /// 屏幕下方居中，从下面轻轻滑上来
    static func present(_ p: NSPanel) {
        let size = p.frame.size
        guard let frame = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame else { p.orderFrontRegardless(); return }
        let final = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80)
        p.setFrameOrigin(NSPoint(x: final.x, y: final.y - 14))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(final)
        }
    }

    enum Kind: Equatable { case success, failure, info }

    /// 看文字猜是哪种提示：✓ 开头 = 成功；有"失败""出错""没能" = 失败；别的 = 普通
    static func kind(of text: String) -> (Kind, String) {
        if text.hasPrefix("✓") { return (.success, String(text.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        if text.hasPrefix("⚠︎") { return (.failure, String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        if ["失败", "出错", "没能", "找不到"].contains(where: text.contains) { return (.failure, text) }
        return (.info, text)
    }

    /// 提示条前面的图标 + 文字
    static func content(_ text: String) -> [NSView] {
        let (kind, rest) = kind(of: text)
        var views: [NSView] = []
        let symbol: (String, NSColor)? = switch kind {
        case .success: ("checkmark.circle.fill", Theme.success)
        case .failure: ("exclamationmark.triangle.fill", Theme.warning)
        case .info: nil
        }
        if let symbol, let image = NSImage(systemSymbolName: symbol.0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = symbol.1
            views.append(icon)
        }
        views.append(Theme.label(rest))
        return views
    }

    /// 只造提示条、不显示（样张、自检也用）
    static func makePanel(_ text: String, action: (@MainActor () -> Void)? = nil) -> NSPanel {
        let row = Theme.row(content(text), spacing: 8, insets: NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 18))
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = action == nil
        p.canHide = false            // 截完图会把焦点还给原来的软件，提示不能跟着消失
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = ToastBackground()
        bg.onClick = action.map { act in { act(); p.orderOut(nil) } }
        let bar = Theme.bar(containing: row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor), bar.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            bar.topAnchor.constraint(equalTo: bg.topAnchor), bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        p.contentView = bg
        p.setContentSize(row.fittingSize)
        return p
    }
}

extension Toast {
    /// 带按钮的提示条（录完：预览剪辑 / 存成 GIF / 在访达中显示）。鼠标停在上面时不会消失
    static func showActions(_ text: String, actions: [(title: String, run: @MainActor () -> Void)], seconds: Double = 8) {
        actionPanel?.orderOut(nil)
        let p = makeActionsPanel(text, actions: actions)
        present(p)
        actionPanel = p
        Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard actionPanel === p, p.isVisible else { return }
                if !p.frame.contains(NSEvent.mouseLocation) { remaining -= 1 }      // 鼠标停在上面就一直留着
            }
            if actionPanel === p { p.orderOut(nil); actionPanel = nil }
        }
    }

    /// 只造带按钮的提示条、不显示（样张、自检也用）
    static func makeActionsPanel(_ text: String, actions: [(title: String, run: @MainActor () -> Void)]) -> NSPanel {
        var views = content(text)
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for action in actions {
            views.append(ToolbarButton(title: action.title, tip: action.title, style: .secondary) {
                p.orderOut(nil)
                action.run()
            })
        }
        let row = Theme.row(views, spacing: 8, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8))
        p.contentView = Theme.bar(containing: row)
        p.setContentSize(row.fittingSize)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.canHide = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    @MainActor private static var actionPanel: NSPanel? {
        get { ToastStorage.actionPanel }
        set { ToastStorage.actionPanel = newValue }
    }
}

@MainActor
private enum ToastStorage {
    static var actionPanel: NSPanel?
}

/// 提示条的底：能点的时候点一下执行动作
@MainActor
final class ToastBackground: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

