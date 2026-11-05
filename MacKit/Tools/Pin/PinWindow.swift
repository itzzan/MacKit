import AppKit
import UniformTypeIdentifiers

/// 一张贴图：浮在所有窗口上面、跨所有桌面和全屏应用的小面板。
/// 点它不会把焦点从你正在用的软件抢走（只有点了贴图，Esc / ⌘W 才作用在它身上）。
@MainActor
final class PinWindow: NSPanel {
    /// 贴出来时的原图。标注另外记，显示、复制、另存时现场合成，所以以后还能接着改。
    /// 转、翻、裁之后换成新的（台阶 13）
    private(set) var originalImage: CGImage
    /// 这张贴图上的标注（带撤销记录，下次进标注接着用）
    let document = AnnotationDocument()
    /// 原图 + 标注合成后的图
    private(set) var renderedImage: CGImage
    var image: CGImage { renderedImage }
    private(set) var annotationSession: PinAnnotationSession?
    var isAnnotating: Bool { annotationSession != nil }
    private(set) var basePointSize: NSSize          // 100% 时的大小（点）
    private(set) var scale: CGFloat
    var onClosed: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// 右键"识别文字"（PinTool 接上）
    var onRecognize: ((CGImage) -> Void)?
    /// 右键"美化…"（PinTool 接上）
    var onBeautify: ((CGImage, CGSize) -> Void)?
    /// 转、翻、裁之前的样子，⌘Z 退回去用（最多记 10 步）
    private struct TransformState {
        let image: CGImage
        let size: NSSize
        let checkpoint: AnnotationDocument.Checkpoint
        let frame: CGRect
        let scale: CGFloat
    }
    private var transformUndo: [TransformState] = []
    var canUndoTransform: Bool { !transformUndo.isEmpty }
    private(set) var cropView: PinCropView?
    var isCropping: Bool { cropView != nil }

    var isClickThrough: Bool { ignoresMouseEvents }
    /// 画面视图。窗口的 contentView 是一个普通的外层视图，画面和标注画板并排放在里面
    /// （画面视图自己管图层，不能往它里面塞子视图）
    private(set) var pinView: PinView?

    init(image: CGImage, pointSize: NSSize, frame: CGRect, scale: CGFloat) {
        self.originalImage = image
        self.renderedImage = image
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

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        let view = PinView(frame: root.bounds, image: image, backingScale: NSScreen.main?.backingScaleFactor ?? 2)
        view.autoresizingMask = [.width, .height]
        view.pin = self
        root.addSubview(view)
        contentView = root
        pinView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeys.handle(event, firstResponder: firstResponder) || super.performKeyEquivalent(with: event)
    }

    // MARK: 标注

    /// 右键"标注"或按空格。present = false 只给自检用：不显示、不抢焦点
    func beginAnnotating(present: Bool = true) {
        guard !isAnnotating, !isClickThrough else { return }
        let session = PinAnnotationSession(pin: self, present: present)
        annotationSession = session
        session.begin()
    }

    /// 标注会话结束（完成或放弃）后调用
    func annotationSessionEnded() {
        annotationSession = nil
        rebuildRenderedImage()
        if let pinView { makeFirstResponder(pinView) }
    }

    /// 标注时贴图本身只显示原图，标注由画板画在上面；结束后换回合成图
    func showOriginalWhileAnnotating(_ on: Bool) {
        pinView?.setImage(on ? originalImage : renderedImage)
    }

    // MARK: 转、翻、裁（台阶 13）

    /// 先把原图和标注合成一张，再转 / 翻，结果当成新的原图；标注压进图里，⌘Z 能退回去
    func transform(_ op: PinImageOp) {
        guard !isAnnotating, !isCropping, let out = PinGeometry.apply(op, to: renderedImage) else { return }
        pushUndo()
        replaceImage(out, size: PinGeometry.size(after: op, basePointSize))
        if op.swapsSize { setFrame(PinGeometry.rotatedFrame(frame), display: true) }
        pinView?.flash(Self.title(of: op))
        Log.app.notice("pin: \(String(describing: op), privacy: .public)")
    }

    static func title(of op: PinImageOp) -> String {
        switch op {
        case .rotateLeft: "向左转 90°"
        case .rotateRight: "向右转 90°"
        case .flipHorizontal: "左右翻转"
        case .flipVertical: "上下翻转"
        }
    }

    /// 只留 rect 这一块（贴图窗口里的坐标，点，左下原点）
    func crop(to rect: CGRect) {
        guard !isAnnotating else { return }
        let base = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
        let imageSize = CGSize(width: renderedImage.width, height: renderedImage.height)
        let px = Geometry.pixelRect(forViewRect: base, viewSize: basePointSize, imageSize: imageSize)
        guard px.width >= 2, px.height >= 2, let cropped = renderedImage.cropping(to: px) else { return }
        let aligned = Geometry.viewRect(forPixelRect: px, viewSize: basePointSize, imageSize: imageSize)
        pushUndo()
        replaceImage(cropped, size: aligned.size)
        setFrame(CGRect(x: (frame.minX + aligned.minX * scale).rounded(), y: (frame.minY + aligned.minY * scale).rounded(),
                        width: max(aligned.width * scale, 16), height: max(aligned.height * scale, 16)), display: true)
        Log.app.notice("pin: cropped to \(cropped.width)x\(cropped.height)")
    }

    /// ⌘Z：退回上一次转 / 翻 / 裁之前（标注也回来、还能改）
    @discardableResult
    func undoTransform() -> Bool {
        guard !isAnnotating, !isCropping, let last = transformUndo.popLast() else { return false }
        originalImage = last.image
        basePointSize = last.size
        document.restore(last.checkpoint)
        scale = last.scale
        rebuildRenderedImage()
        setFrame(last.frame, display: true)
        pinView?.flash("撤回")
        return true
    }

    private func pushUndo() {
        transformUndo.append(TransformState(image: originalImage, size: basePointSize, checkpoint: document.checkpoint(),
                                            frame: frame, scale: scale))
        if transformUndo.count > 10 { transformUndo.removeFirst() }
    }

    private func replaceImage(_ image: CGImage, size: NSSize) {
        originalImage = image
        basePointSize = size
        document.restore(AnnotationDocument().checkpoint())      // 标注已经压进图里
        rebuildRenderedImage()
    }

    /// 右键"裁剪"：贴图上出现可拖的框，回车确定、Esc 不裁了
    func beginCrop(present: Bool = true) {
        guard !isAnnotating, !isCropping, !isClickThrough, let root = contentView else { return }
        let view = PinCropView(frame: root.bounds)
        view.autoresizingMask = [.width, .height]
        view.onFinish = { [weak self] rect in self?.endCrop(rect) }
        root.addSubview(view)
        cropView = view
        if present {
            makeKey()
            makeFirstResponder(view)
            Toast.show("拖边角选要留下的部分，回车确定，Esc 不裁了", seconds: 2.5)
        }
    }

    /// rect = nil：不裁了
    func endCrop(_ rect: CGRect?) {
        guard let view = cropView else { return }
        view.removeFromSuperview()
        cropView = nil
        if let rect, rect.width >= 4, rect.height >= 4, rect.size != view.bounds.size || rect.origin != .zero {
            crop(to: rect)
        }
        if let pinView { makeFirstResponder(pinView) }
    }

    /// 找回关掉的贴图时，把当时的标注放回来
    func restoreAnnotations(_ checkpoint: AnnotationDocument.Checkpoint) {
        document.restore(checkpoint)
        rebuildRenderedImage()
    }

    private func rebuildRenderedImage() {
        if document.items.isEmpty {
            renderedImage = originalImage
        } else if let result = AnnotationExporter.export(
            image: originalImage, viewSize: basePointSize, selection: CGRect(origin: .zero, size: basePointSize),
            screenOrigin: .zero, annotations: document.items,
            mosaic: MosaicSource(image: originalImage, viewSize: basePointSize)) {
            renderedImage = result.image
        }
        pinView?.setImage(renderedImage)
    }

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
        let annotate = ActionMenuItem("标注（空格）") { [weak self] in self?.beginAnnotating() }
        annotate.isEnabled = !isClickThrough
        menu.addItem(annotate)
        menu.addItem(ActionMenuItem("识别文字") { [weak self] in
            guard let self else { return }
            self.onRecognize?(self.originalImage)
        })
        menu.addItem(ActionMenuItem("美化…") { [weak self] in
            guard let self else { return }
            self.onBeautify?(self.renderedImage, self.basePointSize)
        })
        menu.addItem(.separator())
        let turnMenu = NSMenu()
        for (op, key) in [(PinImageOp.rotateLeft, "1"), (.rotateRight, "2"), (.flipHorizontal, "3"), (.flipVertical, "4")] {
            turnMenu.addItem(ActionMenuItem("\(Self.title(of: op))（\(key)）") { [weak self] in self?.transform(op) })
        }
        let turnItem = NSMenuItem(title: "旋转和翻转", action: nil, keyEquivalent: "")
        turnItem.submenu = turnMenu
        turnItem.isEnabled = !isClickThrough
        menu.addItem(turnItem)
        let crop = ActionMenuItem("裁剪") { [weak self] in self?.beginCrop() }
        crop.isEnabled = !isClickThrough
        menu.addItem(crop)
        if canUndoTransform {
            menu.addItem(ActionMenuItem("撤回上一次转 / 翻 / 裁", key: "z", modifiers: .command) { [weak self] in self?.undoTransform() })
        }
        menu.addItem(.separator())
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

    private static let accent = Theme.accent.cgColor
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

    func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

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
        borderLayer.borderColor = on ? Theme.warning.cgColor : Self.idleBorder      // 穿透中：黄色提醒
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
        switch event.keyCode {
        case 53: pin?.closePin()                    // Esc
        case 49: pin?.beginAnnotating()             // 空格：进标注（Snipaste 的习惯）
        // 1 / 2 转、3 / 4 翻（和 Snipaste 一样，台阶 13 拍板）
        case 18: pin?.transform(.rotateLeft)
        case 19: pin?.transform(.rotateRight)
        case 20: pin?.transform(.flipHorizontal)
        case 21: pin?.transform(.flipVertical)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 标注中：⌘W/⌘C 这些不作用在贴图上，交给标注画板（⌘Z 撤销等）
        guard let pin, !pin.isAnnotating, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "w": pin.closePin()
        case "c": pin.copyImage()
        case "s": pin.saveAs()
        case "0": pin.resetSize()
        case "z": pin.undoTransform()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// 裁剪贴图时盖在上面的框：框外变暗，拖 8 个小方块改大小、拖框里挪位置；回车 / 双击确定，Esc 不裁了
@MainActor
final class PinCropView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private(set) var cropRect: CGRect
    private enum Drag { case resize(SelectionHandle, CGRect), move(CGPoint, CGRect) }
    private var drag: Drag?

    override init(frame: NSRect) {
        cropRect = CGRect(origin: .zero, size: frame.size)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cropRect = cropRect.intersection(bounds).isNull ? bounds : cropRect.intersection(bounds)
    }

    func setCrop(_ r: CGRect) {
        cropRect = r.intersection(bounds)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(bounds)
        ctx.addRect(cropRect)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(Theme.accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(cropRect.insetBy(dx: 1, dy: 1))
        for h in SelectionHandle.allCases {
            let c = EditGeometry.handleCenter(h, of: cropRect)
            let dot = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9).intersection(bounds.insetBy(dx: -1, dy: -1))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(dot)
            ctx.setStrokeColor(Theme.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(dot)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, cropRect.contains(p) { onFinish?(cropRect); return }
        if let h = EditGeometry.handle(at: p, in: cropRect, tolerance: 8) {
            drag = .resize(h, cropRect)
        } else if cropRect.contains(p) {
            drag = .move(p, cropRect)
        } else {
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .resize(let h, let original): setCrop(EditGeometry.resize(original, handle: h, to: p, bounds: bounds))
        case .move(let start, let original):
            setCrop(EditGeometry.move(original, by: CGVector(dx: p.x - start.x, dy: p.y - start.y), within: bounds))
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onFinish?(cropRect)          // 回车：确定
        case 53: onFinish?(nil)                   // Esc：不裁了
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
