import AppKit

/// 一次标注的"大脑"：当前工具、颜色、粗细，正在画的那一笔，正在打的字，撤销重做。
/// 鼠标和键盘事件由选区视图转过来；画面由 AnnotationCanvasView 显示。
@MainActor
final class AnnotationEditor: NSObject, NSTextViewDelegate {
    let document: AnnotationDocument
    let canvas: AnnotationCanvasView
    let toolbar: AnnotationToolbar
    /// 工具栏放在画板里（截图）还是交给使用方摆（贴图：放在挂在贴图下方的小窗口里）
    private let embedsToolbar: Bool
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
    /// 选中的是第几条（台阶 12：点一下画好的东西就选中，能拖、能改大小、能换颜色、能删）
    private(set) var selectedIndex: Int?
    private enum EditDrag {
        case move(start: CGPoint, original: Annotation)
        case resize(SelectionHandle, original: Annotation)
        case end(Int, original: Annotation)
    }
    private var editDrag: EditDrag?
    var isDraggingSelection: Bool { editDrag != nil }

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
    var onRecognize: (() -> Void)?
    var onLongShot: (() -> Void)?
    var onBeautify: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 工具栏大小变了（选了工具多出一排），使用方自己摆工具栏时用
    var onToolbarChange: (() -> Void)?

    init(container: NSView, mosaic: MosaicSource, document: AnnotationDocument = AnnotationDocument(),
         customToolbar: AnnotationToolbar? = nil, embedsToolbar: Bool = true) {
        self.container = container
        self.document = document
        self.toolbar = customToolbar ?? AnnotationToolbar()
        self.embedsToolbar = embedsToolbar
        canvas = AnnotationCanvasView(frame: container.bounds)
        canvas.autoresizingMask = [.width, .height]
        canvas.mosaic = mosaic
        color = AnnotationColor(rawValue: Settings.annotationColorIndex) ?? .red
        size = AnnotationSize(rawValue: Settings.annotationSizeIndex) ?? .medium
        super.init()
        container.addSubview(canvas)
        if embedsToolbar { container.addSubview(toolbar) }
        toolbar.onTool = { [weak self] t in self?.selectTool(t) }
        toolbar.onColor = { [weak self] c in self?.setColor(c, remember: true) }
        toolbar.onSize = { [weak self] s in self?.setSize(s, remember: true) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onPin = { [weak self] in self?.onPin?() }
        toolbar.onSave = { [weak self] in self?.onSave?() }
        toolbar.onRecognize = { [weak self] in self?.onRecognize?() }
        toolbar.onLongShot = { [weak self] in self?.onLongShot?() }
        toolbar.onBeautify = { [weak self] in self?.onBeautify?() }
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

    /// 选中了画好的东西时，改的是它（同时记成下次画的默认）
    func setColor(_ c: AnnotationColor, remember: Bool = false) {
        color = c
        if remember { Settings.annotationColorIndex = c.rawValue }
        if let tv = textView {
            styleTextView(tv)
        } else if let i = selectedIndex, document.items.indices.contains(i) {
            var a = document.items[i]
            a.color = c
            document.replace(at: i, with: a)
        }
        refresh()
    }

    func setSize(_ s: AnnotationSize, remember: Bool = false) {
        size = s
        if remember { Settings.annotationSizeIndex = s.rawValue }
        if let tv = textView {
            styleTextView(tv)
            resizeTextView()
        } else if let i = selectedIndex, document.items.indices.contains(i) {
            var a = document.items[i]
            a.size = s
            document.replace(at: i, with: a)
        }
        refresh()
    }

    func undo() {
        guard !isEditingText else { return }
        document.undo()
        selectedIndex = nil
        refresh()
    }

    func redo() {
        guard !isEditingText else { return }
        document.redo()
        selectedIndex = nil
        refresh()
    }

    // MARK: 选中画好的东西（台阶 12）

    /// 鼠标点在哪一条上（叠在一起取最上面的）
    func hitIndex(at p: CGPoint) -> Int? {
        document.items.indices.last { document.items[$0].hit(p) }
    }

    /// 选中的那条，外框上的小方块在哪
    private func handlePoints(of a: Annotation) -> [(SelectionHandle?, Int?, CGPoint)] {
        switch a.handles {
        case .box: return SelectionHandle.allCases.map { (Optional($0), nil, EditGeometry.handleCenter($0, of: a.frame.insetBy(dx: -4, dy: -4))) }
        case .ends: return [(nil, 0, a.points.first ?? .zero), (nil, 1, a.points.last ?? .zero)]
        case .none: return []
        }
    }

    private func handle(at p: CGPoint, of a: Annotation) -> (SelectionHandle?, Int?)? {
        handlePoints(of: a).first { abs(p.x - $0.2.x) <= 6 && abs(p.y - $0.2.y) <= 6 }.map { ($0.0, $0.1) }
    }

    /// 鼠标按下：点在选中那个的小方块上 = 改大小 / 拖箭头一头；点在画好的东西上 = 选中它、准备挪。
    /// 返回 false = 什么都没点中，交给"画新的"
    @discardableResult
    func beginEdit(at p: CGPoint) -> Bool {
        if let i = selectedIndex, document.items.indices.contains(i), let hit = handle(at: p, of: document.items[i]) {
            let original = document.items[i]
            if let h = hit.0 { editDrag = .resize(h, original: original) }
            else if let end = hit.1 { editDrag = .end(end, original: original) }
            document.beginLive()
            return true
        }
        guard let i = hitIndex(at: p) else { return false }
        select(i)
        editDrag = .move(start: p, original: document.items[i])
        document.beginLive()
        NSCursor.closedHand.set()
        return true
    }

    func dragEdit(to p: CGPoint) {
        guard let i = selectedIndex, let editDrag else { return }
        let changed: Annotation
        switch editDrag {
        case .move(let start, let original): changed = original.moved(by: CGVector(dx: p.x - start.x, dy: p.y - start.y))
        case .resize(let h, let original):
            // 小方块画在外框外面 4 点，拖的时候换回到外框上，免得一按下去就跳一下
            let q = CGPoint(x: p.x + (h.movesLeft ? 4 : h.movesRight ? -4 : 0), y: p.y + (h.movesBottom ? 4 : h.movesTop ? -4 : 0))
            changed = original.resized(h, to: q, within: selection.isEmpty ? .infinite : selection)
        case .end(let end, let original): changed = original.withEnd(end, at: p)
        }
        document.updateLive(at: i, with: changed)
        refresh()
    }

    func endEdit(at p: CGPoint) {
        guard editDrag != nil else { return }
        dragEdit(to: p)
        editDrag = nil
        document.endLive()
        refresh()
    }

    func select(_ index: Int?) {
        commitText()
        selectedIndex = index
        if let index, document.items.indices.contains(index) {
            // 工具栏显示它的颜色、粗细（不记成默认，免得只是点一下就改了下次画的样子）
            color = document.items[index].color
            size = document.items[index].size
        }
        refresh()
    }

    func deselect() {
        guard selectedIndex != nil else { return }
        selectedIndex = nil
        refresh()
    }

    /// ⌫ / Delete：删掉选中的
    @discardableResult
    func deleteSelected() -> Bool {
        guard !isEditingText, let i = selectedIndex, document.items.indices.contains(i) else { return false }
        document.remove(at: i)
        selectedIndex = nil
        refresh()
        return true
    }

    /// 方向键：选中的挪 1 点
    @discardableResult
    func nudgeSelected(by d: CGVector) -> Bool {
        guard !isEditingText, let i = selectedIndex, document.items.indices.contains(i) else { return false }
        document.replace(at: i, with: document.items[i].moved(by: d))
        refresh()
        return true
    }

    /// 鼠标放在选中那个的小方块上、或者画好的东西上：换成对应的指针；别处返回 nil
    func editCursor(at p: CGPoint) -> NSCursor? {
        if isDraggingSelection { return .closedHand }
        if let i = selectedIndex, document.items.indices.contains(i), let hit = handle(at: p, of: document.items[i]) {
            if let h = hit.0 { return NSCursor.frameResize(position: Self.cursorPosition(h), directions: .all) }
            return .crosshair
        }
        if tool == .text, document.textIndex(at: p) != nil { return nil }       // 文字工具点文字 = 接着改
        return hitIndex(at: p) != nil ? .pointingHand : nil
    }

    static func cursorPosition(_ h: SelectionHandle) -> NSCursor.FrameResizePosition {
        switch h {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }

    // MARK: 鼠标

    func mouseDown(at p: CGPoint) {
        guard let tool else { return }
        selectedIndex = nil
        switch tool {
        case .text:
            if !editText(at: p) { startText(at: p) }
        case .number:
            document.add(Annotation(tool: .number, color: color, size: size, points: [p], number: document.nextNumber))
            selectedIndex = document.items.count - 1                  // 放好就选中，马上能挪
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
        if let a = pending, a.isMeaningful {
            document.add(a)
            selectedIndex = document.items.count - 1                  // 画完保持选中，马上能调（拍板）
        }
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
        selectedIndex = nil
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
        if let i = selectedIndex, !document.items.indices.contains(i) { selectedIndex = nil }
        if let i = selectedIndex, textView == nil {
            let a = document.items[i]
            canvas.selectionLook = .init(frame: a.frame, handles: handlePoints(of: a).map(\.2), round: a.handles == .ends)
        } else {
            canvas.selectionLook = nil
        }
        toolbar.update(tool: tool, color: color, size: size, canUndo: document.canUndo, canRedo: document.canRedo,
                       showProperties: tool != nil || selectedIndex != nil)
        layoutToolbar()
        onChange?()
    }

    private func layoutToolbar() {
        guard embedsToolbar else { onToolbarChange?(); return }
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

