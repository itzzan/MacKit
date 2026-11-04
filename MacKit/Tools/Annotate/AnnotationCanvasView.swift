import AppKit

/// 把标注画在冻住的画面上面。只负责显示，鼠标事件穿过它交给下面的选区视图
@MainActor
final class AnnotationCanvasView: NSView {
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var pending: Annotation? { didSet { needsDisplay = true } }
    var clipRect: CGRect = .zero { didSet { needsDisplay = true } }
    var mosaic: MosaicSource?

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
    }
}
