import CoreGraphics

/// 坐标换算（纯计算，有单元测试 Tests/main.swift）
///
/// 三套坐标：
/// - CG 全局坐标：原点在主屏左上角，y 向下（窗口列表用这个）
/// - Cocoa 全局坐标：原点在主屏左下角，y 向上（NSScreen、NSWindow 用这个）
/// - 覆盖层视图坐标：某块屏幕自己的左下角为原点，单位是"点"
/// - 图片像素坐标：截到的整屏图片，原点在左上角，单位是像素
enum Geometry {
    static func cocoaRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 把 CG 全局坐标的窗口框，换成某块屏幕覆盖层里的坐标，并裁到屏幕范围内。
    /// 顺序保持不变（前面的窗口在前），不在这块屏幕上的窗口去掉。
    static func viewRects(forCGWindowFrames frames: [CGRect], screenFrame: CGRect, primaryHeight: CGFloat) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: screenFrame.size)
        return frames.compactMap { frame in
            let local = cocoaRect(fromCG: frame, primaryHeight: primaryHeight)
                .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            let clipped = local.intersection(bounds)
            if clipped.isNull || clipped.width < 1 || clipped.height < 1 { return nil }
            return clipped
        }
    }

    /// 点在哪个窗口上（取最前面那个）
    static func topRect(containing point: CGPoint, in rects: [CGRect]) -> CGRect? {
        rects.first { $0.contains(point) }
    }

    /// 覆盖层里的一个框（点，左下原点）→ 图片里的像素框（左上原点），四舍五入到整像素
    static func pixelRect(forViewRect r: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let x0 = (r.minX * sx).rounded(), x1 = (r.maxX * sx).rounded()
        let y0 = ((viewSize.height - r.maxY) * sy).rounded()
        let y1 = ((viewSize.height - r.minY) * sy).rounded()
        let px = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return px.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// pixelRect 的反向：图片里的像素框（左上原点）→ 覆盖层里的框（点，左下原点）
    static func viewRect(forPixelRect px: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        return CGRect(x: px.minX / sx, y: viewSize.height - px.maxY / sy,
                      width: px.width / sx, height: px.height / sy)
    }
}
