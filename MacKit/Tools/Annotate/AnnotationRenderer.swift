import AppKit
import CoreImage

/// 马赛克、模糊用的"打过码"的整屏画面，按格子大小 / 模糊程度缓存。
/// 格子按屏幕左上角对齐，所以屏幕上看到的和导出的一模一样。
final class MosaicSource {
    let image: CGImage
    let viewSize: CGSize
    private var cache: [Int: CGImage] = [:]
    private var blurCache: [Int: CGImage] = [:]

    init(image: CGImage, viewSize: CGSize) {
        self.image = image
        self.viewSize = viewSize
    }

    private var pixelsPerPoint: CGFloat { CGFloat(image.width) / viewSize.width }

    func pixelated(blockPoints: CGFloat) -> CGImage? {
        let block = max(Int((blockPoints * pixelsPerPoint).rounded()), 2)
        if let hit = cache[block] { return hit }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let sw = (image.width + block - 1) / block, sh = (image.height + block - 1) / block
        // 先缩小（每格取平均色），再按格子原样放大（不插值）
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: CGFloat(sh) - CGFloat(image.height) / CGFloat(block),
                                     width: CGFloat(image.width) / CGFloat(block), height: CGFloat(image.height) / CGFloat(block)))
        guard let smallImage = small.makeImage(),
              let big = CGContext(data: nil, width: sw * block, height: sh * block, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: sw * block, height: sh * block))
        let result = big.makeImage()
        cache[block] = result
        return result
    }

    /// 整张画面做高斯模糊（台阶 12）。边缘先往外延伸再模糊，框贴着屏幕边时也不会发黑
    func blurred(radiusPoints: CGFloat) -> CGImage? {
        let radius = max(Int((radiusPoints * pixelsPerPoint).rounded()), 1)
        if let hit = blurCache[radius] { return hit }
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: input.extent)
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = CIContext().createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space) else { return nil }
        blurCache[radius] = result
        return result
    }

    /// 打码图在视图里的位置（和屏幕左上角对齐）
    func drawRect(for pixelated: CGImage) -> CGRect {
        let w = CGFloat(pixelated.width) / pixelsPerPoint, h = CGFloat(pixelated.height) / pixelsPerPoint
        return CGRect(x: 0, y: viewSize.height - h, width: w, height: h)
    }
}

/// 文字标注的排版：显示、导出、编辑框都用这一套，位置才对得上
enum AnnotationText {
    static func font(_ size: AnnotationSize) -> NSFont { .systemFont(ofSize: size.fontSize, weight: .medium) }

    static func attributes(color: AnnotationColor, size: AnnotationSize) -> [NSAttributedString.Key: Any] {
        [.font: font(size), .foregroundColor: color.nsColor]
    }

    static func size(of text: String, color: AnnotationColor, size: AnnotationSize) -> CGSize {
        let shown = text.isEmpty ? " " : text
        let box = NSAttributedString(string: shown, attributes: attributes(color: color, size: size))
            .boundingRect(with: CGSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(box.width) + 2, height: ceil(box.height))
    }

    /// points[0] 是文字框左上角
    static func rect(for a: Annotation) -> CGRect {
        let topLeft = a.points.first ?? .zero
        let s = size(of: a.text, color: a.color, size: a.size)
        return CGRect(x: topLeft.x, y: topLeft.y - s.height, width: s.width, height: s.height)
    }
}

/// 把标注画到 CGContext 上。屏幕显示和导出共用
enum AnnotationRenderer {
    static func draw(_ a: Annotation, in ctx: CGContext, mosaic: MosaicSource?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = a.color.cgColor

        switch a.tool {
        case .rect:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.size.lineWidth)
            ctx.setLineJoin(.miter)
            ctx.stroke(a.box)

        case .ellipse:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.size.lineWidth)
            ctx.strokeEllipse(in: a.box)

        case .arrow:
            guard let start = a.points.first, let end = a.points.last else { return }
            let head = EditGeometry.arrow(from: start, to: end, lineWidth: a.size.lineWidth)
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(a.size.lineWidth)
            ctx.move(to: start)
            ctx.addLine(to: head.shaftEnd)
            ctx.strokePath()
            ctx.move(to: head.tip)
            ctx.addLine(to: head.left)
            ctx.addLine(to: head.right)
            ctx.closePath()
            ctx.fillPath()

        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            let width = a.tool == .pen ? a.size.lineWidth : a.size.highlighterWidth
            ctx.setStrokeColor(a.tool == .pen ? color : color.copy(alpha: 0.4) ?? color)
            ctx.setLineWidth(width)
            if a.points.count == 1 {                       // 只点了一下：画个圆点
                ctx.setFillColor(a.tool == .pen ? color : color.copy(alpha: 0.4) ?? color)
                ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            } else {
                ctx.addLines(between: a.points)            // 一整条路径一次画完，荧光笔重叠处不会越描越深
                ctx.strokePath()
            }

        case .mosaic:
            guard let mosaic, let pixelated = mosaic.pixelated(blockPoints: a.size.mosaicBlock) else { return }
            ctx.clip(to: a.box)
            ctx.interpolationQuality = .none
            ctx.draw(pixelated, in: mosaic.drawRect(for: pixelated))

        case .blur:
            guard let mosaic, let blurred = mosaic.blurred(radiusPoints: a.size.blurRadius) else { return }
            ctx.clip(to: a.box)
            ctx.interpolationQuality = .high
            ctx.draw(blurred, in: mosaic.drawRect(for: blurred))

        case .text:
            let rect = AnnotationText.rect(for: a)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            NSAttributedString(string: a.text, attributes: AnnotationText.attributes(color: a.color, size: a.size))
                .draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()

        case .number:
            guard let center = a.points.first else { return }
            let d = a.size.numberDiameter
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
            let label = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                .foregroundColor: a.color == .white || a.color == .yellow ? NSColor.black : NSColor.white,
            ])
            let s = label.size()
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            label.draw(at: CGPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// 导出：冻住的整屏图 → 裁出选区 → 按 Retina 像素画上标注
enum AnnotationExporter {
    static func export(image: CGImage, viewSize: CGSize, selection: CGRect, screenOrigin: CGPoint,
                       annotations: [Annotation], mosaic: MosaicSource?) -> SelectionResult? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let px = Geometry.pixelRect(forViewRect: selection, viewSize: viewSize, imageSize: imageSize)
        guard px.width >= 1, px.height >= 1, let cropped = image.cropping(to: px) else { return nil }
        let aligned = Geometry.viewRect(forPixelRect: px, viewSize: viewSize, imageSize: imageSize)
        let result = { (img: CGImage) in
            SelectionResult(image: img, pointSize: aligned.size,
                            globalFrame: aligned.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
        }
        if annotations.isEmpty { return result(cropped) }

        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: px.width, height: px.height))
        let scale = imageSize.width / viewSize.width
        ctx.scaleBy(x: scale, y: scale)                    // 之后按"点"画，自动是 Retina 清晰度
        ctx.translateBy(x: -aligned.minX, y: -aligned.minY)
        for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaic) }
        guard let out = ctx.makeImage() else { return nil }
        return result(out)
    }
}
