import AppKit

/// 测量的冻住画面：鼠标停在哪，就往四个方向自动找边，画出十字线和宽高；拖框量框的大小
@MainActor
final class MeasureView: NSView {
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private let scale: CGFloat                    // 图片像素 / 点
    private let backingScale: CGFloat
    private let imageLayer = CALayer()
    private let lines = CAShapeLayer()
    private let box = CAShapeLayer()
    private let widthLabel = LabelLayer()
    private let heightLabel = LabelLayer()
    private let infoLabel = LabelLayer()
    private lazy var pixels: PixelBuffer? = PixelBuffer(image: image)
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var dragged = false
    private var lastMouse: CGPoint?
    /// 现在量到的大小（屏幕像素）；自检用
    private(set) var measuredPixels: (width: Int, height: Int)?

    init(frame: NSRect, image: CGImage, backingScale: CGFloat) {
        self.image = image
        self.backingScale = backingScale
        scale = CGFloat(image.width) / frame.width
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.contentsScale = backingScale
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        for shape in [lines, box] {
            shape.frame = bounds
            shape.fillColor = nil
            shape.lineWidth = 1
        }
        lines.strokeColor = NSColor.systemPink.cgColor
        box.strokeColor = NSColor.systemPink.cgColor
        box.fillColor = NSColor.systemPink.withAlphaComponent(0.12).cgColor
        for sub in [imageLayer, lines, box, widthLabel, heightLabel, infoLabel] as [CALayer] { root.addSublayer(sub) }
        for l in [widthLabel, heightLabel, infoLabel] { l.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: 量

    private func pixelPoint(_ p: CGPoint) -> (Int, Int) {
        (min(max(Int(p.x * scale), 0), image.width - 1), min(max(Int((bounds.height - p.y) * scale), 0), image.height - 1))
    }

    /// 鼠标停在 p：往四个方向找边
    func measureEdges(at p: CGPoint) {
        guard let pixels else { return }
        lastMouse = p
        let (px, py) = pixelPoint(p)
        let d = EdgeFinder.distances(fromX: px, y: py, width: image.width, height: image.height, pixel: pixels.rgb)
        let wPx = d.left + d.right + 1, hPx = d.up + d.down + 1
        measuredPixels = (wPx, hPx)
        let x0 = CGFloat(px - d.left) / scale, x1 = CGFloat(px + d.right + 1) / scale
        let yTop = bounds.height - CGFloat(py - d.up) / scale, yBottom = bounds.height - CGFloat(py + d.down + 1) / scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: p.y)); path.addLine(to: CGPoint(x: x1, y: p.y))
        path.move(to: CGPoint(x: p.x, y: yBottom)); path.addLine(to: CGPoint(x: p.x, y: yTop))
        for (a, b) in [(CGPoint(x: x0, y: p.y - 4), CGPoint(x: x0, y: p.y + 4)), (CGPoint(x: x1, y: p.y - 4), CGPoint(x: x1, y: p.y + 4)),
                       (CGPoint(x: p.x - 4, y: yBottom), CGPoint(x: p.x + 4, y: yBottom)), (CGPoint(x: p.x - 4, y: yTop), CGPoint(x: p.x + 4, y: yTop))] {
            path.move(to: a); path.addLine(to: b)               // 两头的短横
        }
        lines.path = path
        lines.isHidden = false
        box.isHidden = true
        let w = widthLabel.set("宽 " + MeasureText.points(wPx, scale: scale), scale: backingScale)
        widthLabel.frame = CGRect(x: (x0 + x1) / 2 - w.width / 2, y: min(p.y + 6, bounds.maxY - w.height), width: w.width, height: w.height)
        let h = heightLabel.set("高 " + MeasureText.points(hPx, scale: scale), scale: backingScale)
        heightLabel.frame = CGRect(x: min(p.x + 6, bounds.maxX - h.width), y: (yTop + yBottom) / 2 - h.height / 2,
                                   width: h.width, height: h.height)
        widthLabel.isHidden = false
        heightLabel.isHidden = false
        showInfo(widthPixels: wPx, heightPixels: hPx, near: p)
    }

    /// 拖框：量框的大小
    func measureBox(from a: CGPoint, to b: CGPoint) {
        let r = Geometry.rect(from: a, to: b)
        let px = Geometry.pixelRect(forViewRect: r, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
        measuredPixels = (Int(px.width), Int(px.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.path = CGPath(rect: r, transform: nil)
        box.isHidden = false
        lines.isHidden = true
        widthLabel.isHidden = true
        heightLabel.isHidden = true
        CATransaction.commit()
        showInfo(widthPixels: Int(px.width), heightPixels: Int(px.height), near: b)
    }

    private func showInfo(widthPixels w: Int, heightPixels h: Int, near p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let text = MeasureText.size(widthPixels: w, heightPixels: h, scale: scale)
        let size = infoLabel.set("\(text.points) 点（\(text.pixels) 像素）　单击或 C 复制　Esc 退出", scale: backingScale)
        infoLabel.frame = CGRect(origin: MagnifierGeometry.origin(size: size, cursor: p, bounds: bounds), size: size)
        infoLabel.isHidden = false
        CATransaction.commit()
    }

    /// 复制现在量到的大小（点）："120 × 48"
    var copyText: String? {
        measuredPixels.map { MeasureText.size(widthPixels: $0.width, heightPixels: $0.height, scale: scale).points }
    }

    // MARK: 鼠标键盘

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard dragStart == nil else { return }
        measureEdges(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragged && hypot(p.x - start.x, p.y - start.y) < 4 { return }
        dragged = true
        measureBox(from: start, to: p)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = dragged
        dragStart = nil
        dragged = false
        if !wasDrag, let text = copyText { onCopy?(text) }      // 单击 = 复制
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        let arrows: [UInt16: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                          125: CGVector(dx: 0, dy: -1), 126: CGVector(dx: 0, dy: 1)]
        switch event.keyCode {
        case 53: onCancel?()
        case 8: if let text = copyText { onCopy?(text) }        // C
        default:
            if let d = arrows[event.keyCode], let p = lastMouse, let window {
                let next = CGPoint(x: p.x + d.dx, y: p.y + d.dy)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? window.frame.height
                CGWarpMouseCursorPosition(CGPoint(x: window.frame.minX + next.x, y: primaryHeight - (window.frame.minY + next.y)))
                measureEdges(at: next)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// 一次测量：每块屏幕一个冻住的画面
@MainActor
final class MeasureSession {
    private(set) static weak var active: MeasureSession?
    var onFinish: ((String?) -> Void)?
    private var overlays: [OverlayWindow] = []

    init(screens: [FrozenScreen]) {
        let mouse = NSEvent.mouseLocation
        var key: OverlayWindow?
        for frozen in screens {
            let frame = frozen.screen.frame
            let view = MeasureView(frame: NSRect(origin: .zero, size: frame.size), image: frozen.image,
                                   backingScale: frozen.screen.backingScaleFactor)
            view.onCopy = { [weak self] text in self?.end(text) }
            view.onCancel = { [weak self] in self?.end(nil) }
            let w = OverlayWindow(frame: frame)
            w.contentView = view
            overlays.append(w)
            if NSMouseInRect(mouse, frame, false) { key = w }
        }
        keyOverlay = key ?? overlays.first
    }

    private var keyOverlay: OverlayWindow?

    func begin() {
        Self.active = self
        NSApp.activate(ignoringOtherApps: true)
        for w in overlays { w.orderFrontRegardless() }
        keyOverlay?.makeKey()
        if let view = keyOverlay?.contentView { keyOverlay?.makeFirstResponder(view) }
        NSCursor.crosshair.set()
    }

    private func end(_ text: String?) {
        guard !overlays.isEmpty else { return }
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
        if Self.active === self { Self.active = nil }
        let callback = onFinish
        onFinish = nil
        callback?(text)
        if NSApp.modalWindow == nil { NSApp.hide(nil) }
    }
}

/// 测量积木：⌘6 冻住屏幕，自动找边量宽高、拖框量大小，单击或 C 复制"宽 × 高"
@MainActor
final class MeasureTool: ToolModule {
    private(set) var hotKeyRegistered = false
    private var hotKeyID: UInt32?
    private var session: MeasureSession?
    private var isPreparing = false

    func activate() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = HotKeyCenter.shared.register(RecognizeHotKeyPresets.measure[Settings.measureHotKeyIndex]) { [weak self] in
            self?.start()
        }
        hotKeyRegistered = hotKeyID != nil
    }

    func start(delay: Double = 0) {
        guard session == nil, !isPreparing, SelectionSession.active == nil, MeasureSession.active == nil else { return }
        guard ScreenPermission.readyToTry() else { return }
        isPreparing = true
        Task { @MainActor in
            defer { self.isPreparing = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                let frozen = try await ScreenCapturer.capture()
                guard !frozen.isEmpty else { return }
                let s = MeasureSession(screens: frozen)
                s.onFinish = { [weak self] text in
                    self?.session = nil
                    guard let text else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Toast.show("✓ 已复制尺寸 \(text)")
                }
                self.session = s
                s.begin()
            } catch {
                Log.capture.error("measure: capture failed \(error.localizedDescription, privacy: .public)")
                ScreenPermission.showGuide()
            }
        }
    }

    func menuItems() -> [NSMenuItem] {
        let combo = RecognizeHotKeyPresets.measure[Settings.measureHotKeyIndex]
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("测量（自动量宽高、拖框量大小）", key: hotKeyRegistered ? combo.menuKey : "",
                                    modifiers: combo.menuModifiers) { [weak self] in self?.start(delay: 0.2) })
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo.display) 没注册上，可能被别的软件占用，换一个试试"))
        }
        let keyMenu = NSMenu()
        for (index, preset) in RecognizeHotKeyPresets.measure.enumerated() {
            let item = ActionMenuItem("\(preset.display)　\(preset.note)") { [weak self] in
                Settings.measureHotKeyIndex = index
                self?.registerHotKey()
            }
            item.state = index == Settings.measureHotKeyIndex ? .on : .off
            keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "测量快捷键：\(combo.display)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
        return items
    }
}
