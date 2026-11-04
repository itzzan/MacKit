import AppKit
import UniformTypeIdentifiers

/// 一张贴图：浮在所有窗口上面、跨所有桌面和全屏应用的小面板。
/// 点它不会把焦点从你正在用的软件抢走（只有点了贴图，Esc / ⌘W 才作用在它身上）。
@MainActor
final class PinWindow: NSPanel {
    let image: CGImage
    let basePointSize: NSSize          // 100% 时的大小（点）
    private(set) var scale: CGFloat
    var onClosed: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?

    var isClickThrough: Bool { ignoresMouseEvents }
    private var pinView: PinView? { contentView as? PinView }

    init(image: CGImage, pointSize: NSSize, frame: CGRect, scale: CGFloat) {
        self.image = image
        self.basePointSize = pointSize
        self.scale = PinGeometry.clampScale(scale)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        canHide = false                 // 截完图 MacKit 会把自己藏起来交还焦点，贴图不能跟着消失
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = PinView(frame: CGRect(origin: .zero, size: frame.size), image: image,
                           backingScale: NSScreen.main?.backingScaleFactor ?? 2)
        view.pin = self
        contentView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        pinView?.setFocused(true)
    }

    override func resignKey() {
        super.resignKey()
        pinView?.setFocused(false)
    }

    // MARK: 操作

    func zoom(to newScale: CGFloat, anchor: CGPoint) {
        let s = PinGeometry.clampScale(newScale)
        let size = CGSize(width: max(basePointSize.width * s, 16), height: max(basePointSize.height * s, 16))
        setFrame(PinGeometry.zoomedFrame(frame, anchor: anchor, newSize: size), display: true)
        scale = s
        pinView?.flash("\(Int((s * 100).rounded()))%")
    }

    func resetSize() {
        zoom(to: 1, anchor: CGPoint(x: frame.midX, y: frame.midY))
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = PinGeometry.clampOpacity(value)
        pinView?.flash("透明度 \(Int((alphaValue * 100).rounded()))%")
    }

    func setClickThrough(_ on: Bool) {
        ignoresMouseEvents = on
        if on && alphaValue > 0.7 { alphaValue = 0.7 }      // 变成"玻璃"，一眼看出来
        if !on && alphaValue == 0.7 { alphaValue = 1 }
        pinView?.setClickThroughLook(on)
    }

    func copyImage() {
        guard let png = ImageOutput.pngData(of: image, pointSize: basePointSize) else { return }
        ImageOutput.copyToClipboard(image, pointSize: basePointSize, png: png)
        Toast.show("✓ 已复制这张贴图")
    }

    /// 另存为：用不卡人的方式打开保存窗口（见 SelectionSession.saveAs 的说明）
    func saveAs() {
        guard let png = ImageOutput.pngData(of: image, pointSize: basePointSize) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.saveFolder
        panel.nameFieldStringValue = "MacKit_贴图_\(SelectionSession.timestamp()).png"
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try png.write(to: url, options: .atomic)
                    Toast.show("✓ 已保存")
                } catch {
                    Toast.show("保存失败：\(error.localizedDescription)", seconds: 3)
                }
            }
        }
    }

    func closePin() {
        orderOut(nil)
        let callback = onClosed
        onClosed = nil
        callback?(self)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("复制", key: "c", modifiers: .command) { [weak self] in self?.copyImage() })
        menu.addItem(ActionMenuItem("另存为…", key: "s", modifiers: .command) { [weak self] in self?.saveAs() })
        menu.addItem(.separator())

        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = ActionMenuItem("\(percent)%") { [weak self] in self?.setOpacity(CGFloat(percent) / 100) }
            item.state = abs(alphaValue * 100 - CGFloat(percent)) < 5 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "透明度（⌥ + 滚轮）", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let reset = ActionMenuItem("原始大小（现在 \(Int((scale * 100).rounded()))%）", key: "0", modifiers: .command) { [weak self] in
            self?.resetSize()
        }
        reset.isEnabled = abs(scale - 1) > 0.001
        menu.addItem(reset)
        menu.addItem(ActionMenuItem("鼠标穿透（点击会穿过这张图）") { [weak self] in
            self?.setClickThrough(true)
            Toast.show("已穿透。要取消：菜单栏 MacKit →「取消所有穿透」", seconds: 3)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("关闭（Esc）") { [weak self] in self?.closePin() })
        menu.addItem(ActionMenuItem("关闭全部贴图") { [weak self] in self?.onCloseAll?() })
        menu.autoenablesItems = false
        return menu
    }
}

/// 贴图里面的画面：图片 + 细边框 + 缩放/透明度的小提示
@MainActor
final class PinView: NSView {
    weak var pin: PinWindow?

    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let badge = LabelLayer()
    private let backingScale: CGFloat
    private var badgeGeneration = 0

    private static let accent = NSColor(srgbRed: 0.12, green: 0.56, blue: 1.0, alpha: 1).cgColor
    private static let idleBorder = NSColor(white: 0.5, alpha: 0.6).cgColor

    init(frame: NSRect, image: CGImage, backingScale: CGFloat) {
        self.backingScale = backingScale
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.contentsScale = backingScale

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest       // 放大后像素清晰（你的 Snipaste 也关了平滑缩放）
        imageLayer.minificationFilter = .trilinear
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        borderLayer.frame = bounds
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        borderLayer.borderWidth = 1
        borderLayer.borderColor = Self.idleBorder

        badge.isHidden = true
        for sub in [imageLayer, borderLayer, badge] { root.addSublayer(sub) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setFocused(_ focused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.borderColor = focused ? Self.accent : Self.idleBorder
        borderLayer.borderWidth = focused ? 2 : 1
        CATransaction.commit()
    }

    func setClickThroughLook(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.borderColor = on ? NSColor.systemOrange.cgColor : Self.idleBorder
        CATransaction.commit()
    }

    /// 左上角一闪而过的小标签，例如"150%"
    func flash(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = badge.set(text, scale: backingScale)
        badge.frame = CGRect(x: 6, y: bounds.maxY - size.height - 6, width: size.width, height: size.height)
        badge.isHidden = false
        CATransaction.commit()
        badgeGeneration += 1
        let mine = badgeGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard mine == self.badgeGeneration else { return }
            self.badge.isHidden = true
        }
    }

    // MARK: 鼠标和键盘

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        window?.makeKey()
        NSMenu.popUpContextMenu(pin.makeContextMenu(), with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pin else { return }
        // 统一成"手指 / 滚轮往上 = 正数"，不受"自然滚动"设置影响
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.option) {
            pin.setOpacity(PinGeometry.opacity(after: pin.alphaValue, delta: delta, precise: precise))
        } else {
            pin.zoom(to: pin.scale * PinGeometry.scrollZoomFactor(delta: delta, precise: precise),
                     anchor: NSEvent.mouseLocation)
        }
    }

    /// 触控板双指捏合
    override func magnify(with event: NSEvent) {
        guard let pin else { return }
        pin.zoom(to: pin.scale * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pin?.closePin() } else { super.keyDown(with: event) }    // Esc
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let pin, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "w": pin.closePin()
        case "c": pin.copyImage()
        case "s": pin.saveAs()
        case "0": pin.resetSize()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
