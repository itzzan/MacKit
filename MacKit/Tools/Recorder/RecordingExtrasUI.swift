import AppKit
@preconcurrency import AVFoundation
import ApplicationServices

/// 录制时下方的按键牌子：黑底白字，连着按的排成一行（最多 3 个），停手 1.5 秒后慢慢消失。会录进视频
@MainActor
final class KeyCastWindow {
    let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var items: [String] = []
    private var generation = 0
    private var anchor: (target: CGRect, visible: CGRect, fullScreen: Bool)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.level = .statusBar
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        bg.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
        ])
        panel.contentView = bg
    }

    var displayedText: String { label.stringValue }

    func place(target: CGRect, visible: CGRect, fullScreen: Bool) {
        anchor = (target, visible, fullScreen)
    }

    /// 显示一个键（present = false 只给自检用）
    func show(_ text: String, present: Bool = true) {
        items.append(text)
        if items.count > 3 { items.removeFirst(items.count - 3) }
        label.stringValue = items.joined(separator: "　")
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        if let a = anchor {
            panel.setFrameOrigin(RecordGeometry.keyCastOrigin(size: panel.frame.size, target: a.target, visible: a.visible,
                                                              fullScreen: a.fullScreen))
        }
        guard present else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        generation += 1
        let mine = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard mine == self.generation else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self.panel.animator().alphaValue = 0
            }
            guard mine == self.generation else { return }
            self.panel.orderOut(nil)
            self.items.removeAll()
        }
    }

    func close() {
        generation += 1
        panel.orderOut(nil)
        items.removeAll()
    }
}

/// 录制时听你按了什么键，交给按键牌子显示。只在录制中听，录完马上停
@MainActor
final class KeyCaster {
    let window = KeyCastWindow()
    private var monitors: [Any] = []

    /// 需要的权限：辅助功能（你给剪贴板开过）；系统还要"输入监控"时弹提示
    static func ensurePermissions() -> Bool {
        if !AXIsProcessTrusted() {
            ClipboardPaster.requestAccessibility()
            Toast.show("显示按键要用「辅助功能」权限：在系统设置里打开 MacKit 后再试", seconds: 5)
            return false
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            Toast.show("显示按键还要「输入监控」权限：在「系统设置 → 隐私与安全性 → 输入监控」里打开 MacKit", seconds: 6)
            return false
        }
        return true
    }

    func start(target: CGRect, fullScreen: Bool) {
        let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) } ?? NSScreen.main)?
            .visibleFrame ?? target
        window.place(target: target, visible: visible, fullScreen: fullScreen)
        _ = Self.ensurePermissions()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
        Log.capture.notice("record: key cast on")
    }

    func handle(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard let text = KeyFormatter.text(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags),
                                           characters: event.charactersIgnoringModifiers) else { return }
        window.show(text)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        window.close()
    }
}

/// 摄像头画中画：圆形（右键能换圆角方形），能拖、滚轮调大小、右键选小中大。会录进视频
@MainActor
final class CameraBubble {
    enum Size: Int, CaseIterable {
        case small, medium, large
        var side: CGFloat { [120, 180, 260][rawValue] }
        var title: String { ["小", "中", "大"][rawValue] }
    }

    let panel: NSPanel
    let view: CameraBubbleView
    private(set) var rounded: Bool
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "local.mackit.camera")
    var onTurnOff: (() -> Void)?

    init(side: CGFloat, rounded: Bool) {
        self.rounded = rounded
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view = CameraBubbleView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.bubble = self
        applyShape()
    }

    var side: CGFloat { panel.frame.width }

    func place(_ frame: CGRect) { panel.setFrame(frame, display: true) }

    /// 改大小：中心不动
    func setSide(_ newSide: CGFloat) {
        let s = RecordGeometry.clampCameraSide(newSide)
        let f = panel.frame
        panel.setFrame(CGRect(x: f.midX - s / 2, y: f.midY - s / 2, width: s, height: s), display: true)
        Settings.cameraSide = s
        applyShape()
    }

    func setRounded(_ on: Bool) {
        rounded = on
        Settings.cameraRounded = on
        applyShape()
    }

    private func applyShape() {
        view.wantsLayer = true
        view.layer?.cornerRadius = rounded ? 18 : side / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }

    /// 打开摄像头。没权限返回 false
    func start() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        default: return false
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        self.session = session
        view.attach(session)
        panel.orderFrontRegardless()
        sessionQueue.async { session.startRunning() }        // startRunning 会卡住一会儿，放后台
        Log.capture.notice("record: camera on")
        return true
    }

    func close() {
        if let session { sessionQueue.async { session.stopRunning() } }
        session = nil
        panel.orderOut(nil)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for s in Size.allCases {
            let item = ActionMenuItem("\(s.title)（\(Int(s.side)) 点）") { [weak self] in self?.setSide(s.side) }
            item.state = abs(side - s.side) < 1 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let circle = ActionMenuItem("圆形") { [weak self] in self?.setRounded(false) }
        circle.state = rounded ? .off : .on
        menu.addItem(circle)
        let square = ActionMenuItem("圆角方形") { [weak self] in self?.setRounded(true) }
        square.state = rounded ? .on : .off
        menu.addItem(square)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("关掉摄像头") { [weak self] in self?.onTurnOff?() })
        return menu
    }
}

/// 摄像头画面：像照镜子一样左右翻转；拖动换位置；滚轮调大小；右键菜单
@MainActor
final class CameraBubbleView: NSView {
    weak var bubble: CameraBubble?
    private var preview: AVCaptureVideoPreviewLayer?

    func attach(_ session: AVCaptureSession) {
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(layer)
        preview = layer
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let bubble else { return }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        bubble.setSide(bubble.side + delta * (event.hasPreciseScrollingDeltas ? 1 : 12))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let bubble else { return }
        NSMenu.popUpContextMenu(bubble.makeMenu(), with: event, for: self)
    }
}
