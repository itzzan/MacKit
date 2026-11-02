import AppKit

/// 屏幕下方一闪而过的小提示，不抢焦点、鼠标可以穿过去
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ text: String, seconds: Double = 1.8) {
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
        p.ignoresMouseEvents = true
        p.canHide = false            // 截完图会把焦点还给原来的软件，提示不能跟着消失
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
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
