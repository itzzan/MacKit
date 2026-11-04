import CoreGraphics
import Foundation

/// 选区上的 8 个小方块
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// 调整选区、摆工具栏、画箭头头部（纯计算，有单元测试 Tests/main.swift）。
/// 坐标都是覆盖层视图里的点，左下原点，所以"上"是 maxY。
enum EditGeometry {
    static let minSelection: CGFloat = 4

    static func handleCenter(_ handle: SelectionHandle, of r: CGRect) -> CGPoint {
        let x = handle.movesLeft ? r.minX : handle.movesRight ? r.maxX : r.midX
        let y = handle.movesTop ? r.maxY : handle.movesBottom ? r.minY : r.midY
        return CGPoint(x: x, y: y)
    }

    /// 鼠标在哪个小方块上（容差范围内）
    static func handle(at p: CGPoint, in r: CGRect, tolerance: CGFloat = 6) -> SelectionHandle? {
        SelectionHandle.allCases.first { h in
            let c = handleCenter(h, of: r)
            return abs(p.x - c.x) <= tolerance && abs(p.y - c.y) <= tolerance
        }
    }

    /// 拖某个小方块到 p。拖过头会翻过来；结果限制在 bounds 里，最小 4×4
    static func resize(_ r: CGRect, handle: SelectionHandle, to p: CGPoint, bounds: CGRect) -> CGRect {
        let q = CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if handle.movesLeft { x0 = q.x }
        if handle.movesRight { x1 = q.x }
        if handle.movesBottom { y0 = q.y }
        if handle.movesTop { y1 = q.y }
        var out = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        out.size.width = max(out.width, minSelection)
        out.size.height = max(out.height, minSelection)
        out.origin.x = min(out.minX, bounds.maxX - out.width)
        out.origin.y = min(out.minY, bounds.maxY - out.height)
        return out
    }

    /// 整体挪动，不出屏幕
    static func move(_ r: CGRect, by d: CGVector, within bounds: CGRect) -> CGRect {
        var out = r.offsetBy(dx: d.dx, dy: d.dy)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }

    /// 工具栏放哪：优先选区下方右对齐；下面放不下放上方；都放不下放在选区里面右下角
    static func toolbarOrigin(size: CGSize, selection s: CGRect, bounds: CGRect, gap: CGFloat = 8) -> CGPoint {
        var x = s.maxX - size.width
        x = min(max(x, bounds.minX + 4), bounds.maxX - size.width - 4)
        let below = s.minY - gap - size.height
        if below >= bounds.minY + 4 { return CGPoint(x: x, y: below) }
        let above = s.maxY + gap
        if above + size.height <= bounds.maxY - 4 { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: max(s.minY + gap, bounds.minY + 4))
    }

    /// 箭头：杆子画到哪里为止，以及三角形头的三个点（尖、左翼、右翼）
    static func arrow(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat)
        -> (shaftEnd: CGPoint, tip: CGPoint, left: CGPoint, right: CGPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        let head = min(max(lineWidth * 4, 10), max(length * 0.6, 1))
        let halfWidth = head * 0.5
        let ux = length > 0 ? (b.x - a.x) / length : 1
        let uy = length > 0 ? (b.y - a.y) / length : 0
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let left = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        let right = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        let shaftEnd = CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)
        return (shaftEnd, b, left, right)
    }
}
