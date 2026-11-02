import AppKit

struct SelectionResult {
    let image: CGImage
    let pointSize: NSSize
    let globalFrame: CGRect          // 截取的区域在屏幕上的位置（Cocoa 全局坐标，点），贴图贴回原位用
}

/// 能拿到键盘焦点的无边框窗口（不然收不到 Esc）
final class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 一次截图选区：每块屏幕一个覆盖层，选完或取消就全部收起
@MainActor
final class SelectionSession {
    var onFinish: ((SelectionResult?) -> Void)?

    private let screens: [FrozenScreen]
    private let windowFrames: [CGRect]
    private var overlays: [OverlayWindow] = []

    init(screens: [FrozenScreen], windowFrames: [CGRect]) {
        self.screens = screens
        self.windowFrames = windowFrames
    }

    func begin() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        var keyOverlay: OverlayWindow?

        for frozen in screens {
            let frame = frozen.screen.frame
            let rects = Geometry.viewRects(forCGWindowFrames: windowFrames, screenFrame: frame,
                                           primaryHeight: primaryHeight)
            let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size), image: frozen.image,
                                     windowRects: rects, scale: frozen.screen.backingScaleFactor)
            view.onSelect = { [weak self, weak view] rect in
                guard let self, let view else { return }
                self.end(Self.crop(image: frozen.image, viewSize: view.bounds.size, rect: rect,
                                   screenOrigin: frozen.screen.frame.origin))
            }
            view.onCancel = { [weak self] in self?.end(nil) }

            let overlay = OverlayWindow(frame: frame)
            overlay.contentView = view
            overlays.append(overlay)
            if NSMouseInRect(mouse, frame, false) { keyOverlay = overlay }
        }

        NSApp.activate(ignoringOtherApps: true)
        for overlay in overlays { overlay.orderFrontRegardless() }
        if let key = keyOverlay ?? overlays.first {
            key.makeKey()
            key.makeFirstResponder(key.contentView)
        }
        for overlay in overlays { (overlay.contentView as? SelectionView)?.refreshHover(globalMouse: mouse) }
        NSCursor.crosshair.set()
    }

    /// 从冻住的整屏图里裁出选中的部分
    static func crop(image: CGImage, viewSize: CGSize, rect: CGRect, screenOrigin: CGPoint) -> SelectionResult? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let px = Geometry.pixelRect(forViewRect: rect, viewSize: viewSize, imageSize: imageSize)
        guard px.width >= 1, px.height >= 1, let cropped = image.cropping(to: px) else { return nil }
        // 用对齐到整像素后的框，贴回去时和原画面严丝合缝
        let aligned = Geometry.viewRect(forPixelRect: px, viewSize: viewSize, imageSize: imageSize)
        return SelectionResult(image: cropped, pointSize: aligned.size,
                               globalFrame: aligned.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
    }

    private func end(_ result: SelectionResult?) {
        guard !overlays.isEmpty else { return }
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()
        let callback = onFinish
        onFinish = nil
        callback?(result)
        NSApp.hide(nil)          // 把焦点还给截图前在用的软件
    }
}
