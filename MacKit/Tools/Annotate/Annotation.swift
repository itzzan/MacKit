import AppKit

/// 标注工具
enum AnnotationTool: String, CaseIterable {
    case rect, ellipse, arrow, pen, highlighter, mosaic, text, number

    var title: String {
        switch self {
        case .rect: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlighter: "荧光笔"
        case .mosaic: "马赛克"
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
        case .rect, .ellipse, .mosaic: return box.width >= 3 && box.height >= 3
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
