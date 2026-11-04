import AppKit

/// 一块屏幕上的选区覆盖层：底下是冻住的屏幕画面，上面盖一层半透明黑，
/// 选中的区域"挖空"显示原样，并在角上标出像素尺寸。
///
/// 三种状态：
/// - choosing：悬停高亮窗口、拖动框选
/// - editing：框定住了，可以拖 8 个小方块改大小、拖框里面挪位置、用标注工具画
/// - idle：别的屏幕正在编辑，这块屏幕只保持变暗
@MainActor
final class SelectionView: NSView {
    enum Mode { case choosing, editing, idle }

    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    var onSave: (() -> Void)?
    /// 框选时按 C：复制鼠标指着的颜色（台阶 7）
    var onColorPick: ((String) -> Void)?

    private(set) var mode: Mode = .choosing
    private(set) var editor: AnnotationEditor?

    /// 当前显示的框（悬停高亮、拖动中、或编辑中的选区）
    var currentSelection: CGRect? { selection }
    /// 最近一次选定时，选的是 windowRects 里的第几个窗口（拖动框选、桌面单击时为 nil）
    private(set) var pickedWindowIndex: Int?
    private var hoverWindowIndex: Int?

    private let image: CGImage
    private let windowRects: [CGRect]
    private let scale: CGFloat

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeLabel = LabelLayer()
    private let hintLabel = LabelLayer()
    private var handleLayers: [SelectionHandle: CALayer] = [:]

    // 放大镜（台阶 7 取色）：鼠标附近 15×15 个像素放大 8 倍，下面写坐标和颜色
    private static let magnifierPixels = 15
    private static let magnifierZoom: CGFloat = 8
    private let magnifier = CALayer()
    private let zoomLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    private let centerLayer = CAShapeLayer()
    private let magnifierLabel = LabelLayer()
    private lazy var pixels: PixelBuffer? = PixelBuffer(image: image)
    private var shiftHeld = false
    private var lastMouse: CGPoint?
    /// 鼠标指着的颜色（sRGB 0–255）；自检用
    private(set) var pointedColor: (Int, Int, Int)?

    private var selection: CGRect?
    private var tracking: NSTrackingArea?

    private enum Drag {
        case none
        case choose(start: CGPoint, moved: Bool)
        case resize(SelectionHandle, original: CGRect)
        case move(start: CGPoint, original: CGRect)
        case draw
    }
    private var drag: Drag = .none

    private static let accent = Theme.accent.cgColor
    private static let hint = "拖动框选区域　·　单击选窗口（桌面上单击 = 整屏）　·　C 复制颜色　·　Esc 或右键取消"

    init(frame: NSRect, image: CGImage, windowRects: [CGRect], scale: CGFloat, hint: String? = nil) {
        self.image = image
        self.windowRects = windowRects
        self.scale = scale
        super.init(frame: frame)

        let root = CALayer()
        layer = root
        wantsLayer = true
        root.contentsScale = scale

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds

        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor

        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = Self.accent
        borderLayer.lineWidth = 2

        for sub in [imageLayer, dimLayer, borderLayer] { root.addSublayer(sub) }
        for handle in SelectionHandle.allCases {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            dot.backgroundColor = NSColor.white.cgColor
            dot.borderColor = Self.accent
            dot.borderWidth = 1.5
            dot.cornerRadius = 1.5
            dot.contentsScale = scale
            dot.isHidden = true
            handleLayers[handle] = dot
            root.addSublayer(dot)
        }
        root.addSublayer(sizeLabel)
        root.addSublayer(hintLabel)
        setUpMagnifier(in: root)

        let hintSize = hintLabel.set(hint ?? Self.hint, scale: scale)
        hintLabel.frame = CGRect(x: bounds.midX - hintSize.width / 2, y: bounds.maxY - 90,
                                 width: hintSize.width, height: hintSize.height)
        updateLayers()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: 状态切换

    /// 框定了：进入编辑（工具栏、标注、调整框）
    func beginEditing(_ editor: AnnotationEditor, selection rect: CGRect) {
        mode = .editing
        self.editor = editor
        selection = rect
        editor.keyView = self
        editor.selection = rect
        editor.onChange = { [weak self] in self?.updateLayers() }
        hintLabel.isHidden = true
        updateLayers()
        updateMagnifier(at: nil)
    }

    // MARK: 放大镜、取色

    private func setUpMagnifier(in root: CALayer) {
        let side = CGFloat(Self.magnifierPixels) * Self.magnifierZoom
        magnifier.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        magnifier.anchorPoint = .zero
        magnifier.backgroundColor = NSColor.black.cgColor
        magnifier.borderColor = NSColor.white.cgColor
        magnifier.borderWidth = 2
        magnifier.cornerRadius = Theme.labelRadius
        magnifier.masksToBounds = true
        magnifier.isHidden = true
        zoomLayer.frame = magnifier.bounds
        zoomLayer.magnificationFilter = .nearest
        zoomLayer.contentsGravity = .resize
        let grid = CGMutablePath()
        for i in 1..<Self.magnifierPixels {
            let v = CGFloat(i) * Self.magnifierZoom
            grid.move(to: CGPoint(x: v, y: 0)); grid.addLine(to: CGPoint(x: v, y: side))
            grid.move(to: CGPoint(x: 0, y: v)); grid.addLine(to: CGPoint(x: side, y: v))
        }
        gridLayer.path = grid
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        gridLayer.lineWidth = 0.5
        gridLayer.frame = magnifier.bounds
        let c = CGFloat(Self.magnifierPixels / 2) * Self.magnifierZoom
        centerLayer.path = CGPath(rect: CGRect(x: c, y: c, width: Self.magnifierZoom, height: Self.magnifierZoom), transform: nil)
        centerLayer.strokeColor = NSColor.white.cgColor
        centerLayer.fillColor = nil
        centerLayer.lineWidth = 1.5
        centerLayer.frame = magnifier.bounds
        for sub in [zoomLayer, gridLayer, centerLayer] { magnifier.addSublayer(sub) }
        magnifier.contentsScale = scale
        root.addSublayer(magnifier)
        magnifierLabel.isHidden = true
        root.addSublayer(magnifierLabel)
    }

    /// 鼠标指着的点（覆盖层坐标）→ 图片像素（左上原点）
    private func pixelPoint(_ p: CGPoint) -> (Int, Int) {
        let s = CGFloat(image.width) / bounds.width
        return (Int((p.x * s).rounded(.down)), Int(((bounds.height - p.y) * s).rounded(.down)))
    }

    /// 选区状态下跟着鼠标走；编辑中、别的屏幕在编辑时收起
    func updateMagnifier(at p: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lastMouse = p
        guard mode == .choosing, let p, bounds.contains(p), let pixels else {
            magnifier.isHidden = true
            magnifierLabel.isHidden = true
            return
        }
        let (px, py) = pixelPoint(p)
        let half = Self.magnifierPixels / 2
        let cx = min(max(px, half), image.width - half - 1), cy = min(max(py, half), image.height - half - 1)
        zoomLayer.contents = image.cropping(to: CGRect(x: cx - half, y: cy - half,
                                                       width: Self.magnifierPixels, height: Self.magnifierPixels))
        let color = pixels.rgb(px, py)
        pointedColor = color
        let useHex = Settings.colorAsHex != shiftHeld                 // 按住 ⇧ 临时换另一种
        let colorText = ColorText.text(color.0, color.1, color.2, hex: useHex)
        let labelSize = magnifierLabel.set("\(Int(p.x)), \(Int(bounds.height - p.y))　\(colorText)　C 复制", scale: scale)
        let side = magnifier.bounds.width
        let total = CGSize(width: max(side, labelSize.width), height: side + 4 + labelSize.height)
        let origin = MagnifierGeometry.origin(size: total, cursor: p, bounds: bounds)
        magnifier.position = CGPoint(x: origin.x, y: origin.y + labelSize.height + 4)
        magnifierLabel.frame = CGRect(origin: origin, size: labelSize)
        magnifier.isHidden = false
        magnifierLabel.isHidden = false
    }

    /// 现在指着的颜色写成文字（按住 ⇧ 时换成另一种格式）
    var pointedColorText: String? {
        guard let c = pointedColor else { return nil }
        return ColorText.text(c.0, c.1, c.2, hex: Settings.colorAsHex != shiftHeld)
    }

    override func flagsChanged(with event: NSEvent) {
        shiftHeld = event.modifierFlags.contains(.shift)
        updateMagnifier(at: lastMouse)
    }

    /// 方向键：鼠标一次挪 1 个点
    private func nudgeMouse(_ d: CGVector) {
        guard let window, let p = lastMouse else { return }
        let next = CGPoint(x: min(max(p.x + d.dx, 0), bounds.maxX - 1), y: min(max(p.y + d.dy, 0), bounds.maxY - 1))
        let global = CGPoint(x: window.frame.minX + next.x, y: window.frame.minY + next.y)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.frame.height
        CGWarpMouseCursorPosition(CGPoint(x: global.x, y: primaryHeight - global.y))
        selection = hoverRect(at: next)
        updateLayers()
        updateMagnifier(at: next)
    }

    /// 别的屏幕在编辑：这块只保持变暗
    func goIdle() {
        mode = .idle
        selection = nil
        hintLabel.isHidden = true
        updateLayers()
        updateMagnifier(at: nil)
    }

    // MARK: 画

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let showHandles = mode == .editing && (editor?.canAdjustSelection ?? false)
        guard let sel = selection else {
            dimLayer.path = CGPath(rect: bounds, transform: nil)
            borderLayer.isHidden = true
            sizeLabel.isHidden = true
            for dot in handleLayers.values { dot.isHidden = true }
            return
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(sel)
        dimLayer.path = path
        borderLayer.path = CGPath(rect: sel.insetBy(dx: 1, dy: 1), transform: nil)
        borderLayer.isHidden = false
        for (handle, dot) in handleLayers {
            dot.position = EditGeometry.handleCenter(handle, of: sel)
            dot.isHidden = !showHandles
        }

        let px = Geometry.pixelRect(forViewRect: sel, viewSize: bounds.size,
                                    imageSize: CGSize(width: image.width, height: image.height))
        let size = sizeLabel.set("\(Int(px.width)) × \(Int(px.height))", scale: scale)
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 6)
        if origin.y + size.height > bounds.maxY {          // 上面放不下就放进框里
            origin = CGPoint(x: sel.minX + 6, y: sel.maxY - size.height - 6)
        }
        origin.x = min(max(origin.x, 0), bounds.maxX - size.width)
        sizeLabel.frame = CGRect(origin: origin, size: size)
        sizeLabel.isHidden = false
    }

    private func hoverRect(at point: CGPoint) -> CGRect {
        hoverWindowIndex = windowRects.firstIndex { $0.contains(point) }
        return Geometry.topRect(containing: point, in: windowRects) ?? bounds
    }

    /// 刚弹出覆盖层时，按鼠标位置先高亮一次
    func refreshHover(globalMouse: CGPoint) {
        guard mode == .choosing, let window else { return }
        let local = CGPoint(x: globalMouse.x - window.frame.minX, y: globalMouse.y - window.frame.minY)
        selection = bounds.contains(local) ? hoverRect(at: local) : nil
        updateLayers()
    }

    private func setSelection(_ rect: CGRect) {
        selection = rect
        editor?.selection = rect
        updateLayers()
    }

    // MARK: 鼠标指针

    private func cursor(at p: CGPoint) -> NSCursor {
        switch mode {
        case .choosing: return .crosshair
        case .idle: return .arrow
        case .editing:
            guard let editor, let sel = selection else { return .arrow }
            if editor.toolbar.frame.contains(p) { return .arrow }            // 工具栏上用普通箭头
            if let tv = editor.textView, tv.frame.contains(p) { return .iBeam }
            if editor.canAdjustSelection, let h = EditGeometry.handle(at: p, in: sel) {
                return NSCursor.frameResize(position: Self.cursorPosition(h), directions: .all)
            }
            guard sel.contains(p) else { return .arrow }
            if (editor.tool == nil || editor.tool == .text), editor.document.textIndex(at: p) != nil { return .iBeam }
            if let tool = editor.tool { return tool == .text ? .iBeam : .crosshair }
            return editor.canAdjustSelection ? .openHand : .arrow
        }
    }

    private static func cursorPosition(_ h: SelectionHandle) -> NSCursor.FrameResizePosition {
        switch h {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    // MARK: 鼠标

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .none = drag { cursor(at: p).set() }
        if mode == .choosing { updateMagnifier(at: p) }
        guard mode == .choosing, case .none = drag else { return }
        selection = hoverRect(at: p)
        updateLayers()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        updateMagnifier(at: nil)
        guard mode == .choosing, case .none = drag else { return }
        selection = nil
        updateLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .idle:
            drag = .none
        case .choosing:
            drag = .choose(start: p, moved: false)
        case .editing:
            guard let editor, let sel = selection else { return }
            if editor.isEditingText {                                // 点别处 = 打完字
                editor.commitText()
                drag = .none
            } else if event.clickCount >= 2, editor.tool == nil, sel.contains(p) {
                drag = .none
                if !editor.editText(at: p) {                         // 双击文字 = 接着改
                    onDone?()                                        // 没选工具时双击框里别处 = 完成
                }
            } else if editor.canAdjustSelection, let h = EditGeometry.handle(at: p, in: sel) {
                drag = .resize(h, original: sel)
            } else if let tool = editor.tool, sel.contains(p) {
                editor.mouseDown(at: p)
                drag = tool.isClickTool ? .none : .draw
            } else if editor.canAdjustSelection, sel.contains(p) {
                drag = .move(start: p, original: sel)
                NSCursor.closedHand.set()
            } else {
                drag = .none
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .choose(let start, let moved):
            p.x = min(max(p.x, 0), bounds.maxX)
            p.y = min(max(p.y, 0), bounds.maxY)
            if !moved && hypot(p.x - start.x, p.y - start.y) < 4 { return }   // 手抖不算拖动
            drag = .choose(start: start, moved: true)
            hintLabel.isHidden = true
            selection = Geometry.rect(from: start, to: p)
            updateLayers()
            updateMagnifier(at: p)
        case .resize(let handle, let original):
            setSelection(EditGeometry.resize(original, handle: handle, to: p, bounds: bounds))
        case .move(let start, let original):
            setSelection(EditGeometry.move(original, by: CGVector(dx: p.x - start.x, dy: p.y - start.y), within: bounds))
        case .draw:
            editor?.mouseDragged(to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let finished = drag
        drag = .none
        switch finished {
        case .choose(let start, let moved):
            if moved {
                if let sel = selection, sel.width >= 2, sel.height >= 2 {
                    pickedWindowIndex = nil
                    onSelect?(sel)
                } else {
                    selection = hoverRect(at: p)
                    updateLayers()
                }
            } else {
                let rect = hoverRect(at: start)      // 单击 = 选中鼠标下的窗口或整屏
                pickedWindowIndex = hoverWindowIndex
                onSelect?(rect)
            }
        case .draw:
            editor?.mouseUp(at: p)
        case .move:
            cursor(at: p).set()
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        if code == 53 { onCancel?(); return }                         // Esc
        switch mode {
        case .choosing:
            let arrows: [Int: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                           125: CGVector(dx: 0, dy: -1), 126: CGVector(dx: 0, dy: 1)]
            if code == 36 || code == 76, let sel = selection {                    // 回车
                pickedWindowIndex = hoverWindowIndex
                onSelect?(sel)
            } else if code == 8, let text = pointedColorText {                   // C：复制颜色
                onColorPick?(text)
            } else if let d = arrows[code] {
                nudgeMouse(d)
            } else {
                super.keyDown(with: event)
            }
        case .editing:
            guard let editor, let sel = selection else { return }
            if code == 36 || code == 76 { onDone?(); return }
            let arrows: [Int: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                           125: CGVector(dx: 0, dy: -1), 126: CGVector(dx: 0, dy: 1)]
            if let d = arrows[code] {
                if editor.canAdjustSelection { setSelection(EditGeometry.move(sel, by: d, within: bounds)) }
                return
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
               let tool = AnnotationTool.forKey(key) {
                editor.selectTool(tool)
                cursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)).set()
                return
            }
            super.keyDown(with: event)
        case .idle:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard mode == .editing, let editor else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, mods.contains(.shift)) {
        case ("z", false) where !editor.isEditingText: editor.undo()
        case ("z", true) where !editor.isEditingText: editor.redo()
        case ("s", _): onSave?()
        case ("c", _) where !editor.isEditingText: onDone?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
