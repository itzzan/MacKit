import AppKit

/// 把标注画在冻住的画面上面。只负责显示，鼠标事件穿过它交给下面的选区视图
@MainActor
final class AnnotationCanvasView: NSView {
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var pending: Annotation? { didSet { needsDisplay = true } }
    var clipRect: CGRect = .zero { didSet { needsDisplay = true } }
    var mosaic: MosaicSource?
    /// 选中的那个：外面一圈虚线框和小方块（台阶 12）。只画在屏幕上，导出的图里没有
    struct SelectionLook: Equatable {
        var frame: CGRect
        var handles: [CGPoint]
        var round: Bool                 // 箭头的头尾用小圆点
    }
    var selectionLook: SelectionLook? { didSet { if selectionLook != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !clipRect.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: clipRect)
        for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaic) }
        if let pending { AnnotationRenderer.draw(pending, in: ctx, mosaic: mosaic) }
        ctx.restoreGState()
        guard let look = selectionLook else { return }
        // 虚线框：白底蓝虚线，压在什么颜色上都看得见
        let frame = look.frame.insetBy(dx: -4, dy: -4)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.stroke(frame)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.setStrokeColor(Theme.accent.cgColor)
        ctx.stroke(frame)
        ctx.setLineDash(phase: 0, lengths: [])
        for c in look.handles {
            let dot = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(Theme.accent.cgColor)
            ctx.setLineWidth(1.5)
            if look.round {
                ctx.fillEllipse(in: dot)
                ctx.strokeEllipse(in: dot)
            } else {
                ctx.fill(dot)
                ctx.stroke(dot)
            }
        }
    }
}
