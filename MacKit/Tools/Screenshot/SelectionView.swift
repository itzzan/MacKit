import AppKit

/// 一块屏幕上的选区覆盖层：底下是冻住的屏幕画面，上面盖一层半透明黑，
/// 选中的区域"挖空"显示原样，并在角上标出像素尺寸。
@MainActor
final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 当前显示的框（悬停高亮或拖动中），自检用
    var currentSelection: CGRect? { selection }

    private let image: CGImage
    private let windowRects: [CGRect]
    private let scale: CGFloat

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeLabel = LabelLayer()
    private let hintLabel = LabelLayer()

    private var selection: CGRect?
    private var dragStart: CGPoint?
    private var isDragging = false
    private var tracking: NSTrackingArea?

    private static let accent = NSColor(srgbRed: 0.12, green: 0.56, blue: 1.0, alpha: 1).cgColor
    private static let hint = "拖动框选区域　·　单击选窗口（桌面上单击 = 整屏）　·　回车确认　·　Esc 或右键取消"

    init(frame: NSRect, image: CGImage, windowRects: [CGRect], scale: CGFloat) {
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

        for sub in [imageLayer, dimLayer, borderLayer, sizeLabel, hintLabel] { root.addSublayer(sub) }

        let hintSize = hintLabel.set(Self.hint, scale: scale)
        hintLabel.frame = CGRect(x: bounds.midX - hintSize.width / 2, y: bounds.maxY - 90,
                                 width: hintSize.width, height: hintSize.height)
        updateLayers()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: 画

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let sel = selection else {
            dimLayer.path = CGPath(rect: bounds, transform: nil)
            borderLayer.isHidden = true
            sizeLabel.isHidden = true
            return
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(sel)
        dimLayer.path = path
        borderLayer.path = CGPath(rect: sel.insetBy(dx: 1, dy: 1), transform: nil)
        borderLayer.isHidden = false

        let px = Geometry.pixelRect(forViewRect: sel, viewSize: bounds.size,
                                    imageSize: CGSize(width: image.width, height: image.height))
        let size = sizeLabel.set("\(Int(px.width)) × \(Int(px.height))", scale: scale)
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 4)
        if origin.y + size.height > bounds.maxY {          // 上面放不下就放进框里
            origin = CGPoint(x: sel.minX + 4, y: sel.maxY - size.height - 4)
        }
        origin.x = min(max(origin.x, 0), bounds.maxX - size.width)
        sizeLabel.frame = CGRect(origin: origin, size: size)
        sizeLabel.isHidden = false
    }

    private func hoverRect(at point: CGPoint) -> CGRect {
        Geometry.topRect(containing: point, in: windowRects) ?? bounds
    }

    /// 刚弹出覆盖层时，按鼠标位置先高亮一次
    func refreshHover(globalMouse: CGPoint) {
        guard let window else { return }
        let local = CGPoint(x: globalMouse.x - window.frame.minX, y: globalMouse.y - window.frame.minY)
        selection = bounds.contains(local) ? hoverRect(at: local) : nil
        updateLayers()
    }

    // MARK: 鼠标和键盘

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

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard dragStart == nil else { return }
        selection = hoverRect(at: convert(event.locationInWindow, from: nil))
        updateLayers()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else { return }
        selection = nil
        updateLayers()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.maxX)
        p.y = min(max(p.y, 0), bounds.maxY)
        if !isDragging && hypot(p.x - start.x, p.y - start.y) < 4 { return }   // 手抖不算拖动
        isDragging = true
        hintLabel.isHidden = true
        selection = Geometry.rect(from: start, to: p)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        if isDragging {
            isDragging = false
            if let sel = selection, sel.width >= 2, sel.height >= 2 {
                onSelect?(sel)
            } else {
                selection = hoverRect(at: convert(event.locationInWindow, from: nil))
                updateLayers()
            }
        } else {
            onSelect?(hoverRect(at: start))      // 单击 = 选中鼠标下的窗口或整屏
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:                                  // Esc
            onCancel?()
        case 36, 76:                              // 回车
            if let sel = selection { onSelect?(sel) }
        default:
            super.keyDown(with: event)
        }
    }
}
