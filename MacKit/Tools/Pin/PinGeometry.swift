import CoreGraphics
import Foundation

/// 贴图的缩放、透明度、摆放位置（纯计算，有单元测试 Tests/main.swift）
enum PinGeometry {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 10
    static let minOpacity: CGFloat = 0.1

    static func clampScale(_ s: CGFloat) -> CGFloat { min(max(s, minScale), maxScale) }

    static func clampOpacity(_ a: CGFloat) -> CGFloat { min(max(a, minOpacity), 1) }

    /// 以 anchor 为不动点缩放：鼠标指着哪里，就从哪里放大
    static func zoomedFrame(_ frame: CGRect, anchor: CGPoint, newSize: CGSize) -> CGRect {
        let rx = (anchor.x - frame.minX) / frame.width
        let ry = (anchor.y - frame.minY) / frame.height
        return CGRect(x: anchor.x - rx * newSize.width, y: anchor.y - ry * newSize.height,
                      width: newSize.width, height: newSize.height)
    }

    /// 滚轮一下的缩放倍数。鼠标滚轮一格 10%；触控板是连续的小步
    static func scrollZoomFactor(delta: CGFloat, precise: Bool) -> CGFloat {
        if precise { return exp(delta * 0.01) }
        let steps = min(max(delta, -3), 3)
        return pow(1.1, steps)
    }

    /// 滚轮一下后的透明度。鼠标滚轮一格 5%
    static func opacity(after current: CGFloat, delta: CGFloat, precise: Bool) -> CGFloat {
        clampOpacity(current + delta * (precise ? 0.004 : 0.05))
    }

    /// 从剪贴板贴出来的图：以 point 为中心，太大就缩到可见区域的 90%，再整个挪进可见区域
    static func initialPlacement(size: CGSize, around point: CGPoint, visible: CGRect) -> (frame: CGRect, scale: CGFloat) {
        let fit = min(visible.width * 0.9 / size.width, visible.height * 0.9 / size.height, 1)
        let scale = clampScale(fit)
        let w = size.width * scale, h = size.height * scale
        var x = point.x - w / 2, y = point.y - h / 2
        x = min(max(x, visible.minX), visible.maxX - w)
        y = min(max(y, visible.minY), visible.maxY - h)
        return (CGRect(x: x, y: y, width: w, height: h), scale)
    }
}

/// 贴图转、翻（台阶 13）
enum PinImageOp: Equatable {
    case rotateLeft       // 向左转 90°（逆时针）
    case rotateRight      // 向右转 90°（顺时针）
    case flipHorizontal   // 左右翻
    case flipVertical     // 上下翻

    var swapsSize: Bool { self == .rotateLeft || self == .rotateRight }
}

extension PinGeometry {
    /// 转 / 翻之后的大小
    static func size(after op: PinImageOp, _ size: CGSize) -> CGSize {
        op.swapsSize ? CGSize(width: size.height, height: size.width) : size
    }

    /// 转 90° 后贴图窗口的位置：以中心为准，宽高对调
    static func rotatedFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: (frame.midX - frame.height / 2).rounded(), y: (frame.midY - frame.width / 2).rounded(),
               width: frame.height, height: frame.width)
    }

    /// 把整张图转 / 翻一下（按像素画，不糊）
    static func apply(_ op: PinImageOp, to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let out = op.swapsSize ? (h, w) : (w, h)
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: out.0, height: out.1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        switch op {
        case .rotateRight:
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        case .rotateLeft:
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        case .flipHorizontal:
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
