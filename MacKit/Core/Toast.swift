import AppKit

/// 屏幕下方一闪而过的小提示，不抢焦点、鼠标可以穿过去
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    /// action 不为空时提示条能点：点一下执行 action 并收起
    static func show(_ text: String, seconds: Double = 1.8, action: (@MainActor () -> Void)? = nil) {
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let padH: CGFloat = 18, padV: CGFloat = 10
        let size = NSSize(width: ceil(label.frame.width) + padH * 2,
                          height: ceil(label.frame.height) + padV * 2)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = action == nil
        p.canHide = false            // 截完图会把焦点还给原来的软件，提示不能跟着消失
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = ToastBackground(frame: NSRect(origin: .zero, size: size))
        bg.onClick = action.map { act in { act(); p.orderOut(nil) } }
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: padH, y: padV)
        bg.addSubview(label)
        p.contentView = bg

        if let frame = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
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
}

extension Toast {
    /// 带按钮的提示条（录完：预览剪辑 / 存成 GIF / 在访达中显示）。鼠标停在上面时不会消失
    static func showActions(_ text: String, actions: [(title: String, run: @MainActor () -> Void)], seconds: Double = 8) {
        actionPanel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        var views: [NSView] = [label]
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for action in actions {
            let button = ToolbarButton(title: action.title, tip: action.title,
                                       width: CGFloat(action.title.count) * 14 + 24) {
                p.orderOut(nil)
                action.run()
            }
            button.setTitle(action.title)
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor), row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.topAnchor.constraint(equalTo: bg.topAnchor), row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        p.contentView = bg
        let size = row.fittingSize
        p.setContentSize(size)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.canHide = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if let frame = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        p.orderFrontRegardless()
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
final class ToastBackground: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

