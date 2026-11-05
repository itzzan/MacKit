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

    // MARK: 点没点中画好的东西、挪动、拉伸（台阶 12）

    /// 点到线段的距离
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 点到一串折线的距离（画笔、荧光笔）
    static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    /// 点到矩形四条边的距离（框里面的空白不算点中）
    static func distance(_ p: CGPoint, toRectOutline r: CGRect) -> CGFloat {
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                 CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return distance(p, toPolyline: c + [c[0]])
    }

    /// 点到椭圆那一圈的距离（用 72 段折线近似，误差远小于手的抖动）
    static func distance(_ p: CGPoint, toEllipseOutline r: CGRect) -> CGFloat {
        let pts = (0...72).map { i -> CGPoint in
            let t = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
        }
        return distance(p, toPolyline: pts)
    }

    /// 一串点的外框
    static func bounds(of pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for q in pts.dropFirst() { r = r.union(CGRect(origin: q, size: .zero)) }
        return r
    }

    /// 把一串点从旧外框等比例搬到新外框（拉伸画笔）。旧外框某个方向是 0（一条直线）就只平移那个方向
    static func scale(_ pts: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        pts.map { q in
            let x = old.width > 0 ? new.minX + (q.x - old.minX) / old.width * new.width : q.x + (new.midX - old.midX)
            let y = old.height > 0 ? new.minY + (q.y - old.minY) / old.height * new.height : q.y + (new.midY - old.midY)
            return CGPoint(x: x, y: y)
        }
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
