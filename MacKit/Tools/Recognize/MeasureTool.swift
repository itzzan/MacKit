import AppKit

/// 测量的冻住画面：鼠标停在哪，就往四个方向自动找边，画出十字线和宽高；拖框量框的大小。
/// 台阶 24：按空格记下鼠标下面这个东西，再指别的东西：标出两个之间的间距（一个在另一个里面就标四个边距），画对齐线
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
    /// 按空格记下的第一个东西（台阶 24）；nil = 没记
    private(set) var firstBox: PixelBox?
    /// 记下以后，鼠标下面这个东西，和它跟第一个的关系、对齐
    private(set) var secondBox: PixelBox?
    private(set) var relation: MeasureGap.Relation?
    private(set) var alignments: [MeasureGap.Alignment] = []
    /// 下面那行提示（自检看）
    private(set) var infoText = ""
    private var showingBox = false
    private let firstLayer = CAShapeLayer()
    private let secondLayer = CAShapeLayer()
    private let gapLines = CAShapeLayer()
    private let alignLines = CAShapeLayer()
    private let nearLines = CAShapeLayer()
    private var gapLabels: [LabelLayer] = []
    private var nearLabels: [LabelLayer] = []

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
        lines.strokeColor = Theme.accent.cgColor
        box.strokeColor = Theme.accent.cgColor
        box.fillColor = Theme.accent.withAlphaComponent(0.12).cgColor
        // 量间距（台阶 24）：第一个蓝色实框，第二个浅蓝框，间距线蓝色；对齐线红色，差一点的橙色虚线
        for shape in [firstLayer, secondLayer, gapLines, alignLines, nearLines] {
            shape.frame = bounds
            shape.fillColor = nil
            shape.lineWidth = 1
            shape.isHidden = true
        }
        firstLayer.lineWidth = 2
        firstLayer.strokeColor = Theme.accent.cgColor
        firstLayer.fillColor = Theme.accent.withAlphaComponent(0.10).cgColor
        secondLayer.strokeColor = Theme.accent.withAlphaComponent(0.7).cgColor
        secondLayer.fillColor = Theme.accent.withAlphaComponent(0.05).cgColor
        gapLines.strokeColor = Theme.accent.cgColor
        alignLines.strokeColor = NSColor.systemRed.cgColor
        nearLines.strokeColor = NSColor.systemOrange.cgColor
        nearLines.lineDashPattern = [4, 3]
        for sub in [imageLayer, lines, box, firstLayer, secondLayer, alignLines, nearLines, gapLines,
                    widthLabel, heightLabel, infoLabel] as [CALayer] { root.addSublayer(sub) }
        for l in [widthLabel, heightLabel, infoLabel] { l.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: 量

    private func pixelPoint(_ p: CGPoint) -> (Int, Int) {
        (min(max(Int(p.x * scale), 0), image.width - 1), min(max(Int((bounds.height - p.y) * scale), 0), image.height - 1))
    }

    /// 鼠标停在 p：往四个方向找边（记下了第一个东西就改成量两个之间）
    func measureEdges(at p: CGPoint) {
        if firstBox != nil { measurePair(at: p); return }
        guard let pixels else { return }
        lastMouse = p
        showingBox = false
        hidePair()
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
        showingBox = true
        hidePair()
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
        let text = MeasureText.size(widthPixels: w, heightPixels: h, scale: scale)
        showInfo("\(text.points) 点（\(text.pixels) 像素）　单击或 C 复制　空格 记下它、量到别的东西的间距　Esc 退出", near: p)
    }

    private func showInfo(_ text: String, near p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoText = text
        let size = infoLabel.set(text, scale: backingScale)
        infoLabel.frame = CGRect(origin: MagnifierGeometry.origin(size: size, cursor: p, bounds: bounds), size: size)
        infoLabel.isHidden = false
        CATransaction.commit()
    }

    /// 复制现在量到的：大小（点）"120 × 48"；记下了第一个时是间距"12"、边距"上 12 下 12 左 16 右 16"
    var copyText: String? {
        if !showingBox, firstBox != nil { return relation.flatMap { MeasureGap.text($0, scale: scale) } }
        return measuredPixels.map { MeasureText.size(widthPixels: $0.width, heightPixels: $0.height, scale: scale).points }
    }

    // MARK: 量两个东西之间（台阶 24）

    /// 鼠标下面这个东西的框：往四个方向找边，和十字线量到的一样
    func objectBox(at p: CGPoint) -> PixelBox? {
        guard let pixels else { return nil }
        let (px, py) = pixelPoint(p)
        let d = EdgeFinder.distances(fromX: px, y: py, width: image.width, height: image.height, pixel: pixels.rgb)
        return PixelBox(minX: px - d.left, minY: py - d.up, maxX: px + d.right + 1, maxY: py + d.down + 1)
    }

    /// 空格：记下鼠标下面这个东西（再按一次换成新的）
    func markFirst() {
        guard let p = lastMouse, let b = objectBox(at: p) else { return }
        firstBox = b
        measurePair(at: p)
    }

    /// Esc：取消记下的，回到十字线
    func clearFirst() {
        firstBox = nil
        secondBox = nil
        relation = nil
        alignments = []
        hidePair()
        if let p = lastMouse { measureEdges(at: p) }
    }

    private func hidePair() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [firstLayer, secondLayer, gapLines, alignLines, nearLines] { l.isHidden = true }
        for l in gapLabels + nearLabels { l.isHidden = true }
        CATransaction.commit()
    }

    private func viewRect(_ b: PixelBox) -> CGRect {
        CGRect(x: CGFloat(b.minX) / scale, y: bounds.height - CGFloat(b.maxY) / scale,
               width: CGFloat(b.width) / scale, height: CGFloat(b.height) / scale)
    }

    private func vx(_ px: Double) -> CGFloat { CGFloat(px) / scale }
    private func vy(_ py: Double) -> CGFloat { bounds.height - CGFloat(py) / scale }
    private func pt(_ px: Int) -> String { MeasureText.points(px, scale: scale) }

    /// 记下了第一个，鼠标停在 p：框出鼠标下面这个，标间距或边距，画对齐线
    func measurePair(at p: CGPoint) {
        guard let a = firstBox, let b = objectBox(at: p) else { return }
        lastMouse = p
        showingBox = false
        secondBox = b
        let r = MeasureGap.relation(a, b)
        relation = r
        alignments = r == .same ? [] : MeasureGap.alignments(a, b, near: Int((4 * scale).rounded()))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [lines, box] { l.isHidden = true }
        for l in [widthLabel, heightLabel] { l.isHidden = true }
        firstLayer.path = CGPath(rect: viewRect(a).insetBy(dx: 1, dy: 1), transform: nil)
        firstLayer.isHidden = false
        secondLayer.path = CGPath(rect: viewRect(b).insetBy(dx: 0.5, dy: 0.5), transform: nil)
        secondLayer.isHidden = r == .same

        // 间距线：两头带短横，中间标几点
        let gap = CGMutablePath()
        var labels: [(String, CGPoint, Bool)] = []                    // (字, 线的中点, 是横线)
        func dim(_ from: CGPoint, _ to: CGPoint, _ px: Int) {
            let horizontal = from.y == to.y
            gap.move(to: from); gap.addLine(to: to)
            for e in [from, to] {
                gap.move(to: horizontal ? CGPoint(x: e.x, y: e.y - 4) : CGPoint(x: e.x - 4, y: e.y))
                gap.addLine(to: horizontal ? CGPoint(x: e.x, y: e.y + 4) : CGPoint(x: e.x + 4, y: e.y))
            }
            labels.append((pt(px), CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), horizontal))
        }
        switch r {
        case .apart(let h, let v):
            if let h {
                let (left, right) = a.maxX <= b.minX ? (a, b) : (b, a)
                let top = max(a.minY, b.minY), bottom = min(a.maxY, b.maxY)
                let y = top < bottom ? Double(top + bottom) / 2 : Double(b.minY + b.maxY) / 2
                dim(CGPoint(x: vx(Double(left.maxX)), y: vy(y)), CGPoint(x: vx(Double(right.minX)), y: vy(y)), h)
            }
            if let v {
                let (upper, lower) = a.maxY <= b.minY ? (a, b) : (b, a)
                let left = max(a.minX, b.minX), right = min(a.maxX, b.maxX)
                let x = left < right ? Double(left + right) / 2 : Double(b.minX + b.maxX) / 2
                dim(CGPoint(x: vx(x), y: vy(Double(upper.maxY))), CGPoint(x: vx(x), y: vy(Double(lower.minY))), v)
            }
        case .inside(let t, let bo, let l, let rt):
            let (outer, inner) = a.contains(b) ? (a, b) : (b, a)
            let cx = Double(inner.minX + inner.maxX) / 2, cy = Double(inner.minY + inner.maxY) / 2
            dim(CGPoint(x: vx(cx), y: vy(Double(outer.minY))), CGPoint(x: vx(cx), y: vy(Double(inner.minY))), t)
            dim(CGPoint(x: vx(cx), y: vy(Double(inner.maxY))), CGPoint(x: vx(cx), y: vy(Double(outer.maxY))), bo)
            dim(CGPoint(x: vx(Double(outer.minX)), y: vy(cy)), CGPoint(x: vx(Double(inner.minX)), y: vy(cy)), l)
            dim(CGPoint(x: vx(Double(inner.maxX)), y: vy(cy)), CGPoint(x: vx(Double(outer.maxX)), y: vy(cy)), rt)
        case .same, .overlapping:
            break
        }
        gapLines.path = gap
        gapLines.isHidden = labels.isEmpty
        while gapLabels.count < labels.count { let l = LabelLayer(); layer?.addSublayer(l); gapLabels.append(l) }
        for (i, label) in gapLabels.enumerated() {
            guard i < labels.count else { label.isHidden = true; continue }
            let (text, mid, horizontal) = labels[i]
            let size = label.set(text, scale: backingScale)
            let origin = horizontal ? CGPoint(x: mid.x - size.width / 2, y: mid.y + 5) : CGPoint(x: mid.x + 6, y: mid.y - size.height / 2)
            label.frame = CGRect(origin: clamped(origin, size), size: size)
            label.isHidden = false
        }

        // 对齐线：贯穿两个框；对齐的红色实线，差一点的橙色虚线 + "差 N 点"（线都画在第一个的位置上）
        let union = viewRect(a).union(viewRect(b))
        let aligned = CGMutablePath(), nearly = CGMutablePath()
        var nearTexts: [(String, CGPoint)] = []
        for al in alignments {
            let path = al.diff == 0 ? aligned : nearly
            if al.edge.isVertical {
                let x = vx(al.positionA)
                path.move(to: CGPoint(x: x, y: union.minY - 10)); path.addLine(to: CGPoint(x: x, y: union.maxY + 10))
                if al.diff > 0 { nearTexts.append(("差 \(pt(al.diff)) 点", CGPoint(x: x + 3, y: union.maxY + 12))) }
            } else {
                let y = vy(al.positionA)
                path.move(to: CGPoint(x: union.minX - 10, y: y)); path.addLine(to: CGPoint(x: union.maxX + 10, y: y))
                if al.diff > 0 { nearTexts.append(("差 \(pt(al.diff)) 点", CGPoint(x: union.maxX + 12, y: y - 8))) }
            }
        }
        alignLines.path = aligned
        alignLines.isHidden = aligned.isEmpty
        nearLines.path = nearly
        nearLines.isHidden = nearly.isEmpty
        while nearLabels.count < nearTexts.count { let l = LabelLayer(); layer?.addSublayer(l); nearLabels.append(l) }
        for (i, label) in nearLabels.enumerated() {
            guard i < nearTexts.count else { label.isHidden = true; continue }
            let size = label.set(nearTexts[i].0, scale: backingScale)
            label.frame = CGRect(origin: clamped(nearTexts[i].1, size), size: size)
            label.isHidden = false
        }

        // 下面那行提示
        let alignedNames = alignments.filter { $0.diff == 0 }.map(\.edge.name)
        let nearNames = alignments.filter { $0.diff > 0 }.map { "\($0.edge.name)差 \(pt($0.diff)) 点" }
        var info: String
        switch r {
        case .same: info = "这就是记下的那个：指别的东西量间距"
        case .overlapping: info = "叠在一起了：指旁边的东西量间距"
        case .inside: info = "边距 \(MeasureGap.text(r, scale: scale) ?? "")（点）"
        case .apart: info = "间距 \(MeasureGap.text(r, scale: scale) ?? "") 点"
        }
        if !alignedNames.isEmpty { info += "　对齐：" + alignedNames.joined(separator: "、") }
        if !nearNames.isEmpty { info += "　差一点：" + nearNames.joined(separator: "、") }
        info += r == .same || r == .overlapping ? "　Esc 取消记下的" : "　单击或 C 复制　空格 换一个　Esc 取消记下的"
        showInfo(info, near: p)
    }

    /// 标签别出画面
    private func clamped(_ origin: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(origin.x, 2), bounds.maxX - size.width - 2), y: min(max(origin.y, 2), bounds.maxY - size.height - 2))
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
        case 53: if firstBox != nil { clearFirst() } else { onCancel?() }   // Esc：先取消记下的，再退出
        case 49: markFirst()                                   // 空格：记下鼠标下面这个（台阶 24）
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

    func reloadHotKeys() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = Settings.hotKey(.measure).flatMap { HotKeyCenter.shared.register($0) { [weak self] in self?.start() } }
        hotKeyRegistered = Settings.hotKey(.measure) == nil || hotKeyID != nil
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
        let combo = Settings.hotKey(.measure)
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("测量（自动量宽高、拖框量大小）", key: hotKeyRegistered ? (combo?.menuKey ?? "") : "",
                                    modifiers: combo?.menuModifiers ?? []) { [weak self] in self?.start(delay: 0.2) })
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo?.display ?? "") 没注册上，可能被别的软件占用，在「设置 → 快捷键」里换一个"))
        }
        return items
    }

}
