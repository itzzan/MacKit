import AppKit

/// 标注工具
enum AnnotationTool: String, CaseIterable {
    case rect, ellipse, arrow, pen, highlighter, mosaic, blur, text, number

    var title: String {
        switch self {
        case .rect: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlighter: "荧光笔"
        case .mosaic: "马赛克"
        case .blur: "模糊"
        case .text: "文字"
        case .number: "序号"
        }
    }

    /// 单键快捷键
    var key: String {
        switch self {
        case .rect: "r"
        case .ellipse: "e"
        case .arrow: "a"
        case .pen: "p"
        case .highlighter: "h"
        case .mosaic: "m"
        case .blur: "b"
        case .text: "t"
        case .number: "n"
        }
    }

    var symbol: String {
        switch self {
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil"
        case .highlighter: "highlighter"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "drop.halffull"
        case .text: "textformat"
        case .number: "1.circle"
        }
    }

    /// 点一下就放好（不用拖）
    var isClickTool: Bool { self == .text || self == .number }

    static func forKey(_ key: String) -> AnnotationTool? { allCases.first { $0.key == key } }
}

enum AnnotationColor: Int, CaseIterable {
    case red, orange, yellow, green, blue, black, white

    var title: String {
        switch self {
        case .red: "红"
        case .orange: "橙"
        case .yellow: "黄"
        case .green: "绿"
        case .blue: "蓝"
        case .black: "黑"
        case .white: "白"
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        case .orange: CGColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)
        case .yellow: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .green: CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    var nsColor: NSColor { NSColor(cgColor: cgColor) ?? .red }
}

enum AnnotationSize: Int, CaseIterable {
    case thin, medium, thick

    var title: String { ["细", "中", "粗"][rawValue] }
    var lineWidth: CGFloat { [2, 4, 6][rawValue] }
    var highlighterWidth: CGFloat { [10, 16, 24][rawValue] }
    var fontSize: CGFloat { [14, 18, 26][rawValue] }
    var numberDiameter: CGFloat { [20, 26, 34][rawValue] }
    var mosaicBlock: CGFloat { [6, 10, 16][rawValue] }       // 马赛克一格多大（点）
    var blurRadius: CGFloat { [4, 8, 14][rawValue] }         // 模糊：轻 / 中 / 重（点）
}

/// 一条标注。坐标是覆盖层视图里的"点"（左下原点），和选区同一套坐标
struct Annotation: Equatable {
    var tool: AnnotationTool
    var color: AnnotationColor
    var size: AnnotationSize
    /// 矩形/椭圆/箭头/马赛克：[起点, 终点]；画笔/荧光笔：一串点；文字：[左上角]；序号：[圆心]
    var points: [CGPoint]
    var text: String = ""
    var number: Int = 0

    /// 起点终点围成的框（矩形类工具用）
    var box: CGRect {
        guard let first = points.first, let last = points.last else { return .null }
        return Geometry.rect(from: first, to: last)
    }

    /// 太小的就当手抖，不留
    var isMeaningful: Bool {
        switch tool {
        case .rect, .ellipse, .mosaic, .blur: return box.width >= 3 && box.height >= 3
        case .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) >= 5
        case .pen, .highlighter: return !points.isEmpty
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return !points.isEmpty
        }
    }
}

/// 一张图上的所有标注，带撤销/重做。
/// 每次改动前把整份列表存一份（标注很少，存得起），所以加、改、删都能撤销
final class AnnotationDocument {
    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    /// 存档点：标注列表 + 撤销/重做记录
    struct Checkpoint {
        fileprivate let items: [Annotation]
        fileprivate let undoStack: [[Annotation]]
        fileprivate let redoStack: [[Annotation]]
    }

    init(items: [Annotation] = []) {
        self.items = items
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(items: items, undoStack: undoStack, redoStack: redoStack)
    }

    /// 回到存档点（贴图标注按 Esc 放弃这一次画的）
    func restore(_ c: Checkpoint) {
        items = c.items
        undoStack = c.undoStack
        redoStack = c.redoStack
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 下一个序号：已经放了几个序号 + 1
    var nextNumber: Int { items.filter { $0.tool == .number }.count + 1 }

    private func record() {
        undoStack.append(items)
        redoStack.removeAll()
    }

    func add(_ annotation: Annotation) {
        record()
        items.append(annotation)
    }

    func replace(at index: Int, with annotation: Annotation) {
        guard items.indices.contains(index), items[index] != annotation else { return }
        record()
        items[index] = annotation
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        record()
        items.remove(at: index)
    }

    // 拖动选中的标注：拖之前存一份，拖的过程中不记撤销，松手才算一步（台阶 12）
    private var liveBase: [Annotation]?

    func beginLive() { liveBase = items }

    func updateLive(at index: Int, with annotation: Annotation) {
        guard liveBase != nil, items.indices.contains(index) else { return }
        items[index] = annotation
    }

    func endLive() {
        guard let base = liveBase else { return }
        liveBase = nil
        if base != items {
            undoStack.append(base)
            redoStack.removeAll()
        }
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(items)
        items = previous
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(items)
        items = next
        return true
    }

    /// 鼠标点在哪条文字标注上（取最上面那条）
    func textIndex(at p: CGPoint) -> Int? {
        items.indices.last { i in
            items[i].tool == .text && AnnotationText.rect(for: items[i]).insetBy(dx: -4, dy: -4).contains(p)
        }
    }
}

/// 选中、挪动、改大小（台阶 12）。坐标和标注一样是视图里的点，左下原点
extension Annotation {
    /// 选中后小方块怎么摆
    enum Handles { case box, ends, none }

    var handles: Handles {
        switch tool {
        case .rect, .ellipse, .mosaic, .blur, .pen, .highlighter: .box
        case .arrow: .ends
        case .text, .number: .none
        }
    }

    /// 选中时外面那个框
    var frame: CGRect {
        switch tool {
        case .rect, .ellipse, .mosaic, .blur: return box
        case .arrow, .pen, .highlighter: return EditGeometry.bounds(of: points)
        case .text: return AnnotationText.rect(for: self)
        case .number:
            guard let c = points.first else { return .null }
            let d = size.numberDiameter
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
    }

    /// 鼠标点在这里算不算点中它：框、圈只认线条附近，箭头和笔画看离线多近，打码、文字、序号认整块
    func hit(_ p: CGPoint) -> Bool {
        let slack: CGFloat = 4
        switch tool {
        case .rect: return EditGeometry.distance(p, toRectOutline: box) <= size.lineWidth / 2 + slack
        case .ellipse: return EditGeometry.distance(p, toEllipseOutline: box) <= size.lineWidth / 2 + slack
        case .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return EditGeometry.distance(p, toSegment: a, b) <= size.lineWidth / 2 + slack + 1
        case .pen: return EditGeometry.distance(p, toPolyline: points) <= size.lineWidth / 2 + slack
        case .highlighter: return EditGeometry.distance(p, toPolyline: points) <= size.highlighterWidth / 2 + 2
        case .mosaic, .blur: return box.insetBy(dx: -2, dy: -2).contains(p)
        case .text: return frame.insetBy(dx: -4, dy: -4).contains(p)
        case .number:
            guard let c = points.first else { return false }
            return hypot(p.x - c.x, p.y - c.y) <= size.numberDiameter / 2 + 2
        }
    }

    func moved(by d: CGVector) -> Annotation {
        var a = self
        a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return a
    }

    /// 拖外框上的小方块。框类工具改两个角；画笔、荧光笔整串点等比例拉伸
    func resized(_ handle: SelectionHandle, to p: CGPoint, within bounds: CGRect) -> Annotation {
        var a = self
        switch tool {
        case .rect, .ellipse, .mosaic, .blur:
            let r = EditGeometry.resize(box, handle: handle, to: p, bounds: bounds)
            a.points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]
        case .pen, .highlighter:
            let old = frame
            let r = EditGeometry.resize(old, handle: handle, to: p, bounds: bounds)
            a.points = EditGeometry.scale(points, from: old, to: r)
        default:
            break
        }
        return a
    }

    /// 箭头拖头或尾（0 = 起点，1 = 尖）
    func withEnd(_ end: Int, at p: CGPoint) -> Annotation {
        guard tool == .arrow, points.count >= 2 else { return self }
        var a = self
        a.points[end == 0 ? 0 : a.points.count - 1] = p
        return a
    }
}
