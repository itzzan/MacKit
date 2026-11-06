import CoreGraphics
import Foundation

// 长截图的拼接算法（纯计算，有单元测试 Tests/main.swift）
//
// 思路：长截图期间不停地拍框里的画面。每张拍到的画面先算出"每一行的指纹"，
// 和上一张拼进去的画面比，找出往下滚了几行，把新露出来的那几行接到长图下面。
// 网页顶部固定的导航栏、聊天窗口底部的输入框不跟着滚，第一次滚动时认出来，之后比对和拼接都绕开它们，
// 最后头尾各留一份。
//
// 台阶 25 横着拼：把每张画面"转 90 度"（每一列变成一行）交给同一套算法，拼好再转回来。
// 还没认出方向时竖着、横着各拼一份，哪边先接上新内容就定成哪边（DirectionalStitcher）。

/// 拍到的一张画面：每像素 4 字节，从上往下一行行紧挨着排（没有行尾填充）。
/// 颜色顺序是 BGRA 还是 RGBA 都行：算指纹时三个颜色加在一起，拼图时原样照抄
struct StitchFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    var bytesPerRow: Int { width * 4 }

    /// 转 90 度（沿对角线翻）：第 x 列变成第 x 行，左边的列在上面。再转一次就转回来
    func transposed() -> StitchFrame {
        let w = width, h = height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                let src = srcRaw.bindMemory(to: UInt32.self), dst = dstRaw.bindMemory(to: UInt32.self)
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w { dst[x * h + y] = src[row + x] }
                }
            }
        }
        return StitchFrame(width: h, height: w, pixels: out)
    }
}

/// 每一行的"指纹"：把一行切成若干段，每段取平均亮度。比两行只比指纹，快
struct RowPrints {
    let rows: Int
    let bins: Int
    private(set) var values: [Float]
    /// 这一行有没有内容。一整条纯色的空白行和哪儿都对得上，不能拿来判断滚了多少
    private(set) var informative: [Bool]

    init(_ frame: StitchFrame, bins wanted: Int = 32) {
        rows = frame.height
        let bins = max(1, min(wanted, frame.width))
        self.bins = bins
        var values = [Float](repeating: 0, count: frame.height * bins)
        frame.pixels.withUnsafeBufferPointer { px in
            for y in 0..<frame.height {
                let rowStart = y * frame.width * 4
                for b in 0..<bins {
                    let x0 = b * frame.width / bins, x1 = (b + 1) * frame.width / bins
                    var sum = 0
                    var i = rowStart + x0 * 4
                    for _ in x0..<x1 {
                        sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])
                        i += 4
                    }
                    values[y * bins + b] = Float(sum) / Float(3 * max(x1 - x0, 1))
                }
            }
        }
        self.values = values
        var informative = [Bool](repeating: false, count: frame.height)
        for y in 0..<frame.height {
            var lo: Float = 255, hi: Float = 0
            var edge: Float = 0
            for b in 0..<bins {
                let v = values[y * bins + b]
                lo = min(lo, v)
                hi = max(hi, v)
                if y > 0 { edge += abs(v - values[(y - 1) * bins + b]) }
            }
            // 段与段之间有明暗变化（文字、图片），或者和上一行明显不同（分隔线、色块的边）
            informative[y] = hi - lo >= 8 || edge / Float(bins) >= 8
        }
        self.informative = informative
    }

    /// 本帧第 a 行和 other 第 b 行差多少：每段亮度差的平均（0 = 一模一样，255 = 黑白相反）
    func diff(_ a: Int, _ other: RowPrints, _ b: Int) -> Float {
        var sum: Float = 0
        let ia = a * bins, ib = b * other.bins
        values.withUnsafeBufferPointer { va in
            other.values.withUnsafeBufferPointer { vb in
                for k in 0..<bins { sum += abs(va[ia + k] - vb[ib + k]) }
            }
        }
        return sum / Float(bins)
    }
}

/// 两张画面之间怎么动的
enum ScrollMove: Equatable {
    case same          // 没滚（或者只有一小块在变，比如光标闪）
    case down(Int)     // 往下滚了这么多像素
    case up(Int)       // 往回滚了这么多像素
    case lost          // 对不上：滚太快，或者画面整个变了
    case blank         // 几乎全是空白，看不出滚了多少
}

enum ScrollMatcher {
    /// 平均每段亮度差不超过这么多，算"没变"
    static let sameTolerance: Float = 1.5
    /// 重叠部分平均每段亮度差不超过这么多，才算对上了（截图里文字的抗锯齿会有一点点差别）
    static let matchTolerance: Float = 6
    /// 几个重叠位置差不多一样好时（重复的花纹），取滚得最少的那个
    static let tieTolerance: Float = 1
    /// 比对时最多抽这么多行，免得太慢
    static let sampleLimit = 96

    /// 前后两张至少要重叠这么多行才敢拼
    static func minOverlap(content: Int) -> Int { max(8, content / 6) }

    /// 只比中间会滚的部分：[start, end) 行
    static func isSame(_ p: RowPrints, _ n: RowPrints, start: Int, end: Int) -> Bool {
        guard end > start else { return true }
        var sum: Float = 0
        for r in start..<end { sum += n.diff(r, p, r) }
        return sum / Float(end - start) <= sameTolerance
    }

    /// 新一张 n 相对上一张 p 滚了多少：n 的第 r 行 = p 的第 r + d 行（d > 0 是往下滚）。
    /// top、bottom：顶部、底部固定不动的行数，不参与比对
    static func move(from p: RowPrints, to n: RowPrints, top: Int, bottom: Int) -> ScrollMove {
        moveWithCost(from: p, to: n, top: top, bottom: bottom).move
    }

    /// 同上，再交出对得有多准（重叠部分平均每段的亮度差，越小越准；没滚、对不上时是 0 或无穷大）。
    /// 认方向时，竖着、横着都对上了就挑更准的那个（台阶 25）
    static func moveWithCost(from p: RowPrints, to n: RowPrints, top: Int, bottom: Int) -> (move: ScrollMove, cost: Float) {
        guard p.rows == n.rows, p.bins == n.bins else { return (.lost, .infinity) }
        let start = top, end = n.rows - bottom, content = end - start
        guard content >= 8 else { return (.lost, .infinity) }
        if isSame(p, n, start: start, end: end) { return (.same, 0) }

        var samples = (start..<end).filter { n.informative[$0] }
        guard samples.count >= 6 else { return (.blank, .infinity) }
        if samples.count > sampleLimit {
            let step = Double(samples.count) / Double(sampleLimit)
            samples = (0..<sampleLimit).map { samples[Int(Double($0) * step)] }
        }

        // 第一轮：每个可能的位置都用抽出来的几十行粗比一遍
        let maxShift = content - minOverlap(content: content)
        guard maxShift >= 1 else { return (.lost, .infinity) }
        var coarse: [(d: Int, cost: Float)] = []
        coarse.reserveCapacity(2 * maxShift)
        for d in -maxShift...maxShift where d != 0 {
            var sum: Float = 0
            var count = 0
            for r in samples {
                let q = r + d
                if q < start || q >= end { continue }
                sum += n.diff(r, p, q)
                count += 1
            }
            if count >= 3 { coarse.append((d, sum / Float(count))) }
        }
        let candidates = coarse.sorted { $0.cost < $1.cost }.prefix(6)

        // 第二轮：最像的几个位置，用重叠部分的每一行细比
        var fine: [(d: Int, cost: Float)] = []
        for c in candidates {
            var sum: Float = 0
            var count = 0
            for r in start..<end {
                let q = r + c.d
                if q < start || q >= end { continue }
                guard n.informative[r] || p.informative[q] else { continue }
                sum += n.diff(r, p, q)
                count += 1
            }
            if count >= 4 { fine.append((c.d, sum / Float(count))) }
        }
        guard let best = fine.min(by: { $0.cost < $1.cost }), best.cost <= matchTolerance else { return (.lost, .infinity) }
        let chosen = fine.filter { $0.cost <= best.cost + tieTolerance }.min { abs($0.d) < abs($1.d) } ?? best
        return (chosen.d > 0 ? .down(chosen.d) : .up(-chosen.d), chosen.cost)
    }

    /// 顶部、底部有多少行一点没动（固定的导航栏、输入框）。
    /// 顶上或底下恰好是空白时会多算几行空白，不要紧：第一张整张都拼进去，最后一张的底部也会补上
    static func fixedBands(_ a: RowPrints, _ b: RowPrints) -> (top: Int, bottom: Int) {
        guard a.rows == b.rows, a.bins == b.bins else { return (0, 0) }
        var top = 0
        while top < a.rows, b.diff(top, a, top) <= sameTolerance { top += 1 }
        var bottom = 0
        while bottom < a.rows - top, b.diff(a.rows - 1 - bottom, a, a.rows - 1 - bottom) <= sameTolerance { bottom += 1 }
        return (top, bottom)
    }
}

/// 一边收画面一边拼长图。不是线程安全的：只在一个队列里用
final class ScrollStitcher {
    enum Event: Equatable {
        case first             // 第一张
        case same              // 没滚
        case appended(Int)     // 接上了这么多行
        /// 往回滚了：长图末尾跟着退回这么多行（滚回来会再接上）。0 = 滚到比开始的地方还上面，先不管
        case up(Int)
        case lost              // 对不上了
        case blank             // 太空白，看不出来
        case full              // 到上限了
    }

    let maxHeight: Int
    private let thumbWanted: Int
    private(set) var width = 0
    private(set) var frameHeight = 0
    private var firstPrints: RowPrints?
    /// 上一张拼进去的画面（比对用它；最后的底部也从它取）
    private var last: StitchFrame?
    private var lastPrints: RowPrints?
    /// 固定不动的顶部、底部行数。第一次真的滚动时才知道
    private(set) var bands: (top: Int, bottom: Int)?
    /// 已经拼好的部分（不含底部固定的那一条）
    private var canvas: [UInt8] = []
    private(set) var canvasRows = 0
    /// 第一张拼进去的行数：往回滚最多退到这里
    private var baseRows = 0
    /// 预览用的小图（同样的颜色顺序）
    private(set) var thumb: [UInt8] = []
    private(set) var thumbRows = 0
    private(set) var thumbWidth = 0
    private(set) var isFull = false
    /// 最近一次比对对得有多准（认方向用）
    private(set) var lastCost: Float = .infinity

    init(maxHeight: Int = 30000, thumbWidth: Int = 160) {
        self.maxHeight = maxHeight
        self.thumbWanted = thumbWidth
    }

    /// 长图现在多高（像素，含底部固定的那一条）
    var totalHeight: Int { canvasRows + (bands?.bottom ?? 0) }

    /// 大约拼了几屏
    var screens: Double { frameHeight > 0 ? Double(totalHeight) / Double(frameHeight) : 0 }

    func add(_ frame: StitchFrame) -> Event {
        guard !isFull else { return .full }
        guard let firstPrints else {
            width = frame.width
            frameHeight = frame.height
            thumbWidth = max(1, min(thumbWanted, frame.width))
            let prints = RowPrints(frame)
            self.firstPrints = prints
            last = frame
            lastPrints = prints
            canvas = frame.pixels
            canvasRows = frame.height
            updateThumb()
            return .first
        }
        guard frame.width == width, frame.height == frameHeight, let lastPrints else { return .lost }
        let prints = RowPrints(frame)

        if let bands {
            let (move, cost) = ScrollMatcher.moveWithCost(from: lastPrints, to: prints, top: bands.top, bottom: bands.bottom)
            lastCost = cost
            switch move {
            case .down(let d): return append(frame, prints, d)
            case .same: return .same
            case .up(let k): return takeBack(frame, prints, k)
            case .lost: return .lost
            case .blank: return .blank
            }
        }

        // 还没滚过：先看是不是只有一小块在变（光标闪、动图），再认出固定的头尾
        if ScrollMatcher.isSame(firstPrints, prints, start: 0, end: frameHeight) { return .same }
        let found = ScrollMatcher.fixedBands(firstPrints, prints)
        if frameHeight - found.top - found.bottom < frameHeight / 4 { return .same }
        let (move, cost) = ScrollMatcher.moveWithCost(from: firstPrints, to: prints, top: found.top, bottom: found.bottom)
        lastCost = cost
        switch move {
        case .down(let d):
            bands = found
            // 第一张整张都留着，只把底部固定的那一条去掉，之后接在它下面
            canvasRows = frameHeight - found.bottom
            baseRows = canvasRows
            canvas.removeLast(found.bottom * frame.bytesPerRow)
            thumb.removeAll()
            thumbRows = 0
            updateThumb()
            return append(frame, prints, d)
        case .same: return .same
        case .up: return .up(0)
        case .lost: return .lost
        case .blank: return .blank
        }
    }

    /// 往回滚了 k 行：长图末尾也退回 k 行，这一张当成新的"上一张"。
    /// 这样滚到底时页面弹一下（露出一截空白再弹回来）不会把空白留在长图里；往回看几行再往下滚，结果也一样。
    /// 退到比第一张还上面就先不管，等滚回来
    private func takeBack(_ frame: StitchFrame, _ prints: RowPrints, _ k: Int) -> Event {
        guard k > 0, canvasRows - k >= baseRows else { return .up(0) }
        canvas.removeLast(k * frame.bytesPerRow)
        canvasRows -= k
        last = frame
        lastPrints = prints
        let keep = Int(Double(canvasRows) * Double(thumbWidth) / Double(width))
        if keep < thumbRows {
            thumb.removeLast((thumbRows - keep) * thumbWidth * 4)
            thumbRows = keep
        }
        return .up(k)
    }

    /// 新画面里刚露出来的 d 行（紧挨着底部固定条的上面）接到长图下面
    private func append(_ frame: StitchFrame, _ prints: RowPrints, _ d: Int) -> Event {
        guard let bands else { return .lost }
        let room = maxHeight - canvasRows - bands.bottom
        let n = min(d, room)
        guard n > 0 else { isFull = true; return .full }
        let firstNew = frameHeight - bands.bottom - d
        let bpr = frame.bytesPerRow
        canvas.append(contentsOf: frame.pixels[(firstNew * bpr)..<((firstNew + n) * bpr)])
        canvasRows += n
        last = frame
        lastPrints = prints
        updateThumb()
        if n < d { isFull = true; return .full }
        return .appended(n)
    }

    /// 预览小图跟上长图：按宽度等比缩小，取最近的像素
    private func updateThumb() {
        guard width > 0 else { return }
        let scale = Double(thumbWidth) / Double(width)
        let target = Int(Double(canvasRows) * scale)
        guard target > thumbRows else { return }
        let bpr = width * 4
        thumb.reserveCapacity(target * thumbWidth * 4)
        canvas.withUnsafeBufferPointer { src in
            for t in thumbRows..<target {
                let y = min(Int(Double(t) / scale), canvasRows - 1)
                for i in 0..<thumbWidth {
                    let x = min(Int(Double(i) / scale), width - 1)
                    let o = y * bpr + x * 4
                    thumb.append(src[o]); thumb.append(src[o + 1]); thumb.append(src[o + 2]); thumb.append(src[o + 3])
                }
            }
        }
        thumbRows = target
    }

    /// 拼好的长图：已拼部分 + 最后一张的底部固定条。一张都没有时返回 nil
    func result() -> StitchFrame? {
        guard let last, width > 0 else { return nil }
        guard let bands else { return StitchFrame(width: width, height: canvasRows, pixels: canvas) }
        var pixels = canvas
        let bpr = last.bytesPerRow
        pixels.append(contentsOf: last.pixels[((frameHeight - bands.bottom) * bpr)..<(frameHeight * bpr)])
        return StitchFrame(width: width, height: canvasRows + bands.bottom, pixels: pixels)
    }

    /// 预览小图
    func thumbnail() -> StitchFrame? {
        thumbRows > 0 ? StitchFrame(width: thumbWidth, height: thumbRows, pixels: thumb) : nil
    }
}

/// 长截图往哪个方向拼（台阶 25）
enum LongShotAxis: Equatable, Hashable {
    case vertical, horizontal
}

/// 认方向的拼接（台阶 25）：还没认出来时，每张画面竖着、横着各拼一份；哪边先接上新内容就定成哪边，另一份扔掉。
/// 横着拼 = 把画面转 90 度交给同一套算法，拼好再转回来
final class DirectionalStitcher {
    private(set) var axis: LongShotAxis?
    private var vertical: ScrollStitcher?
    private var horizontal: ScrollStitcher?
    /// 最近一张对得上的画面（看"对不上"是不是因为往另一个方向滚了）
    private var lastGood: StitchFrame?
    /// 这一张对不上，是因为往另一个方向滚了（横着拼时上下滚、竖着拼时左右滚）
    private(set) var crossScroll = false

    init(maxLength: Int = 30000, thumbWidth: Int = 160) {
        vertical = ScrollStitcher(maxHeight: maxLength, thumbWidth: thumbWidth)
        horizontal = ScrollStitcher(maxHeight: maxLength, thumbWidth: thumbWidth)
    }

    /// 还没认出方向时按竖着的算
    private var active: ScrollStitcher? { axis == .horizontal ? horizontal : vertical }

    /// 长图沿拼的方向有多长（竖着是高，横着是宽；像素）
    var length: Int { active?.totalHeight ?? 0 }
    var screens: Double { active?.screens ?? 0 }

    func add(_ frame: StitchFrame) -> ScrollStitcher.Event {
        crossScroll = false
        let event: ScrollStitcher.Event
        switch axis {
        case .vertical?:
            event = vertical?.add(frame) ?? .lost
        case .horizontal?:
            event = horizontal?.add(frame.transposed()) ?? .lost
        case nil:
            guard let v0 = vertical, let h0 = horizontal else { return .lost }
            let v = v0.add(frame), h = h0.add(frame.transposed())
            switch (v, h) {
            case (.appended, .appended):
                lock(v0.lastCost <= h0.lastCost ? .vertical : .horizontal)    // 两边都对上了：挑对得更准的
                event = axis == .vertical ? v : h
            case (.appended, _), (.full, _):
                lock(.vertical)
                event = v
            case (_, .appended), (_, .full):
                lock(.horizontal)
                event = h
            default:
                if v == .same || h == .same { event = .same }
                else if v == .lost { event = h }
                else { event = v }
            }
        }
        if event == .lost, let axis, let lastGood { crossScroll = Self.moved(across: axis, from: lastGood, to: frame) }
        if event != .lost && event != .blank { lastGood = frame }
        return event
    }

    private func lock(_ a: LongShotAxis) {
        axis = a
        if a == .vertical { horizontal = nil } else { vertical = nil }
    }

    /// 从 a 到 b 是不是往另一个方向滚了（拼横着的时候看上下，拼竖着的时候看左右）
    static func moved(across axis: LongShotAxis, from a: StitchFrame, to b: StitchFrame) -> Bool {
        let (pa, pb) = axis == .horizontal ? (RowPrints(a), RowPrints(b)) : (RowPrints(a.transposed()), RowPrints(b.transposed()))
        let bands = ScrollMatcher.fixedBands(pa, pb)
        switch ScrollMatcher.move(from: pa, to: pb, top: bands.top, bottom: bands.bottom) {
        case .down, .up: return true
        default: return false
        }
    }

    /// 拼好的长图（横着拼的转回来）
    func result() -> StitchFrame? {
        axis == .horizontal ? horizontal?.result()?.transposed() : vertical?.result()
    }

    /// 预览小图（横着拼的转回来：高是预览条那么高，往右长）
    func thumbnail() -> StitchFrame? {
        axis == .horizontal ? horizontal?.thumbnail()?.transposed() : vertical?.thumbnail()
    }
}

/// 要长截图的那一块屏幕
struct ScreenRegion: Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect          // 这块屏幕（Cocoa 全局坐标，点）
    let viewRect: CGRect             // 框（相对这块屏幕，左下原点，点）

    /// 框在屏幕上的位置（Cocoa 全局坐标）
    var globalRect: CGRect { viewRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY) }

    /// 给 ScreenCaptureKit 的源区域：相对屏幕、左上原点、点，对齐到整像素
    func sourceRect(scale: CGFloat) -> CGRect {
        let top = screenFrame.height - viewRect.maxY
        let x0 = (viewRect.minX * scale).rounded(), y0 = (top * scale).rounded()
        let x1 = (viewRect.maxX * scale).rounded(), y1 = ((top + viewRect.height) * scale).rounded()
        return CGRect(x: x0 / scale, y: y0 / scale, width: (x1 - x0) / scale, height: (y1 - y0) / scale)
    }
}

/// 长截图时控制条、预览条摆在哪（纯计算）
enum LongShotGeometry {
    /// 预览条：放在框的右边，右边放不下放左边，都放不下就贴着框的右边放在框里面
    static func previewFrame(region: CGRect, visible: CGRect, width: CGFloat, gap: CGFloat = 16) -> CGRect {
        let height = min(max(region.height, 160), visible.height - 8)
        var y = region.maxY - height
        y = min(max(y, visible.minY + 4), visible.maxY - height - 4)
        let right = region.maxX + gap
        if right + width <= visible.maxX - 4 { return CGRect(x: right, y: y, width: width, height: height) }
        let left = region.minX - gap - width
        if left >= visible.minX + 4 { return CGRect(x: left, y: y, width: width, height: height) }
        return CGRect(x: min(region.maxX, visible.maxX) - width - 8, y: y, width: width, height: height)
    }

    /// 小图在预览条里怎么放：等宽缩放；比预览条短就靠上，比预览条长就露出最下面（最新拼上的部分）
    static func thumbLayout(thumbSize: CGSize, box: CGSize) -> CGRect {
        guard thumbSize.width > 0 else { return .zero }
        let h = thumbSize.height * box.width / thumbSize.width
        return CGRect(x: 0, y: max(box.height - h, 0), width: box.width, height: h)
    }

    /// 控制条上的进度："已拼约 3.2 屏　6200 像素高"；横着拼是"像素宽"
    static func progressText(totalHeight: Int, screens: Double, axis: LongShotAxis? = nil) -> String {
        let s = screens < 10 ? String(format: "%.1f", screens) : String(Int(screens.rounded()))
        return "已拼约 \(s) 屏　\(totalHeight) 像素\(axis == .horizontal ? "宽" : "高")"
    }

    /// 横着拼时的预览条（台阶 25）：放在框的上面、和框一样宽（至少 160）；上面放不下（或挡着控制条）就放到框和控制条下面，
    /// 都放不下就贴着框的上边放在框里面
    static func horizontalPreviewFrame(region: CGRect, visible: CGRect, height: CGFloat, avoid: CGRect, gap: CGFloat = 16) -> CGRect {
        let width = min(max(region.width, 160), visible.width - 8)
        let x = min(max(region.minX, visible.minX + 4), visible.maxX - width - 4)
        let below = min(region.minY, avoid.isEmpty ? region.minY : avoid.minY) - gap - height
        for y in [region.maxY + gap, max(region.maxY, avoid.maxY) + gap, below] {
            let r = CGRect(x: x, y: y, width: width, height: height)
            if r.minY >= visible.minY + 4, r.maxY <= visible.maxY - 4, !r.intersects(avoid), !r.intersects(region) { return r }
        }
        return CGRect(x: x, y: min(region.maxY, visible.maxY) - height - 8, width: width, height: height)
    }

    /// 横着拼时小图在预览条里怎么放：等高缩放；比预览条窄就靠左，比预览条宽就露出最右边（最新拼上的部分）
    static func horizontalThumbLayout(thumbSize: CGSize, box: CGSize) -> CGRect {
        guard thumbSize.height > 0 else { return .zero }
        let w = thumbSize.width * box.height / thumbSize.height
        return CGRect(x: min(box.width - w, 0), y: 0, width: w, height: box.height)
    }
}
