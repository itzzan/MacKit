import AppKit

/// 一次标注的"大脑"：当前工具、颜色、粗细，正在画的那一笔，正在打的字，撤销重做。
/// 鼠标和键盘事件由选区视图转过来；画面由 AnnotationCanvasView 显示。
@MainActor
final class AnnotationEditor: NSObject, NSTextViewDelegate {
    let document = AnnotationDocument()
    let canvas: AnnotationCanvasView
    let toolbar = AnnotationToolbar()
    private(set) var tool: AnnotationTool?
    private(set) var color: AnnotationColor
    private(set) var size: AnnotationSize
    private weak var container: NSView?
    /// 打完字后键盘焦点还给谁（选区视图）
    weak var keyView: NSView?

    private var pending: Annotation?
    private(set) var textView: AnnotationTextView?
    private var textTopLeft: CGPoint = .zero
    /// 正在改的是第几条已有文字（nil = 新文字）
    private var editingTextIndex: Int?

    /// 选区（视图坐标）。改了以后画布裁剪和工具栏位置跟着变
    var selection: CGRect = .zero {
        didSet {
            canvas.clipRect = selection
            layoutToolbar()
        }
    }

    /// 画了第一笔之后选区就固定，免得标注和框错位
    var canAdjustSelection: Bool { document.items.isEmpty && textView == nil && pending == nil }
    var isEditingText: Bool { textView != nil }

    /// 有变化时通知选区视图刷新（小方块要不要显示等）
    var onChange: (() -> Void)?
    var onDone: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    init(container: NSView, mosaic: MosaicSource) {
        self.container = container
        canvas = AnnotationCanvasView(frame: container.bounds)
        canvas.autoresizingMask = [.width, .height]
        canvas.mosaic = mosaic
        color = AnnotationColor(rawValue: Settings.annotationColorIndex) ?? .red
        size = AnnotationSize(rawValue: Settings.annotationSizeIndex) ?? .medium
        super.init()
        container.addSubview(canvas)
        container.addSubview(toolbar)
        toolbar.onTool = { [weak self] t in self?.selectTool(t) }
        toolbar.onColor = { [weak self] c in self?.setColor(c, remember: true) }
        toolbar.onSize = { [weak self] s in self?.setSize(s, remember: true) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onPin = { [weak self] in self?.onPin?() }
        toolbar.onSave = { [weak self] in self?.onSave?() }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        toolbar.onDone = { [weak self] in self?.onDone?() }
        refresh()
    }

    func tearDown() {
        textView?.removeFromSuperview()
        canvas.removeFromSuperview()
        toolbar.removeFromSuperview()
    }

    // MARK: 工具、颜色、粗细

    /// 再点一次同一个工具 = 放下工具（回到可以调整框的状态）
    func selectTool(_ t: AnnotationTool?) {
        commitText()
        tool = (t == tool) ? nil : t
        refresh()
    }

    func setColor(_ c: AnnotationColor, remember: Bool = false) {
        color = c
        if remember { Settings.annotationColorIndex = c.rawValue }
        if let tv = textView { styleTextView(tv) }
        refresh()
    }

    func setSize(_ s: AnnotationSize, remember: Bool = false) {
        size = s
        if remember { Settings.annotationSizeIndex = s.rawValue }
        if let tv = textView { styleTextView(tv); resizeTextView() }
        refresh()
    }

    func undo() {
        guard !isEditingText else { return }
        document.undo()
        refresh()
    }

    func redo() {
        guard !isEditingText else { return }
        document.redo()
        refresh()
    }

    // MARK: 鼠标

    func mouseDown(at p: CGPoint) {
        guard let tool else { return }
        switch tool {
        case .text:
            if !editText(at: p) { startText(at: p) }
        case .number:
            document.add(Annotation(tool: .number, color: color, size: size, points: [p], number: document.nextNumber))
            refresh()
        case .pen, .highlighter:
            pending = Annotation(tool: tool, color: color, size: size, points: [p])
        default:
            pending = Annotation(tool: tool, color: color, size: size, points: [p, p])
        }
        canvas.pending = pending
    }

    func mouseDragged(to p: CGPoint) {
        guard var a = pending else { return }
        if a.tool == .pen || a.tool == .highlighter {
            if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { a.points.append(p) }
        } else {
            a.points[a.points.count - 1] = p
        }
        pending = a
        canvas.pending = a
    }

    func mouseUp(at p: CGPoint) {
        mouseDragged(to: p)
        if let a = pending, a.isMeaningful { document.add(a) }
        pending = nil
        canvas.pending = nil
        refresh()
    }

    // MARK: 文字

    /// 双击或用文字工具点已有的文字：接着改它。没点在文字上返回 false。
    /// 先把手上正在打的字收好，再按位置重新找（收字可能增删一条，序号会变）
    @discardableResult
    func editText(at p: CGPoint) -> Bool {
        commitText()
        guard let index = document.textIndex(at: p) else { return false }
        let a = document.items[index]
        color = a.color
        size = a.size
        startText(at: a.points.first ?? .zero, text: a.text, editing: index)
        return true
    }

    private func startText(at p: CGPoint, text: String = "", editing index: Int? = nil) {
        guard let container else { return }
        commitText()
        textTopLeft = p
        editingTextIndex = index
        let tv = AnnotationTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 4000, height: 4000)
        // 大小只由我们算（resizeTextView），不让输入框自己伸缩，免得两边抢着改宽度把最后一个字切掉
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.delegate = self
        // 输入法拼写中的拼音也要撑开输入框（2026-11-04：之前只在字定下来时才变宽，拼音被裁掉看不见）
        tv.onTextLayoutChange = { [weak self] in self?.resizeTextView() }
        styleTextView(tv)
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        container.addSubview(tv)
        textView = tv
        resizeTextView()
        container.window?.makeFirstResponder(tv)
        refresh()
    }

    /// 字体、颜色，加一层半透明衬底：打在什么颜色的底上都看得清（最终的图上没有衬底）
    private func styleTextView(_ tv: NSTextView) {
        let light = color == .white || color == .yellow
        tv.font = AnnotationText.font(size)
        tv.textColor = color.nsColor
        tv.insertionPointColor = color.nsColor
        tv.typingAttributes = AnnotationText.attributes(color: color, size: size)
        tv.drawsBackground = true
        tv.backgroundColor = light ? NSColor.black.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.6)
        tv.layer?.borderColor = (light ? NSColor.white : NSColor.black).withAlphaComponent(0.5).cgColor
    }

    private func resizeTextView() {
        guard let tv = textView else { return }
        let s = AnnotationText.size(of: tv.string, color: color, size: size)
        let caret = size.fontSize * 0.6                      // 给光标和下一个字留点地方
        tv.frame = CGRect(x: textTopLeft.x, y: textTopLeft.y - s.height, width: max(s.width + caret, 12), height: s.height)
    }

    func textDidChange(_ notification: Notification) { resizeTextView() }

    /// Esc：结束打字（字留下）
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    /// 把正在打的字变成一条文字标注；改已有文字时替换它，改成空白就删掉
    func commitText() {
        guard let tv = textView else { return }
        if tv.hasMarkedText() { tv.unmarkText() }            // 还在拼写的拼音也算进去
        let a = Annotation(tool: .text, color: color, size: size, points: [textTopLeft], text: tv.string)
        if let index = editingTextIndex {
            if a.isMeaningful { document.replace(at: index, with: a) } else { document.remove(at: index) }
        } else if a.isMeaningful {
            document.add(a)
        }
        editingTextIndex = nil
        tv.removeFromSuperview()
        textView = nil
        if let keyView { keyView.window?.makeFirstResponder(keyView) }
        refresh()
    }

    // MARK: 画面

    private func refresh() {
        // 正在改的那条文字先不画，免得和输入框叠在一起
        canvas.annotations = document.items.enumerated().filter { $0.offset != editingTextIndex }.map(\.element)
        toolbar.update(tool: tool, color: color, size: size, canUndo: document.canUndo, canRedo: document.canRedo)
        layoutToolbar()
        onChange?()
    }

    private func layoutToolbar() {
        guard let container else { return }
        let origin = EditGeometry.toolbarOrigin(size: toolbar.frame.size, selection: selection, bounds: container.bounds)
        toolbar.setFrameOrigin(origin)
    }
}

/// 标注用的文本框：输入法拼写中、删字、粘贴时都通知编辑器重新量大小
@MainActor
final class AnnotationTextView: NSTextView {
    var onTextLayoutChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextLayoutChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onTextLayoutChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onTextLayoutChange?()
    }

    override func didChangeText() {
        super.didChangeText()
        onTextLayoutChange?()
    }
}

