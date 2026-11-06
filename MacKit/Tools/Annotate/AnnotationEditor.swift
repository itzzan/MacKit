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
    /// 打的字用大一档的字号（屏幕画笔，台阶 22）
    var bigText = false

    private var pending: Annotation?
    private(set) var textView: AnnotationTextView?
    private var textTopLeft: CGPoint = .zero
    /// 正在改的是第几条已有文字（nil = 新文字）
    private var editingTextIndex: Int?
    /// 选中的是哪几条（台阶 12：点一下画好的东西就选中，能拖、能改大小、能换颜色、能删；
    /// 台阶 19：⇧ 点加选 / 去掉、⇧ 在空白处拖框选、⌘A 全选，好几个一起拖、删、换颜色）
    private(set) var selectedIndices = IndexSet()
    /// 只选了一个时是第几条（改大小的小方块、拖箭头头尾只在这时有）
    var selectedIndex: Int? { selectedIndices.count == 1 ? selectedIndices.first : nil }
    var hasSelection: Bool { !selectedIndices.isEmpty }
    private enum EditDrag {
        case move(start: CGPoint, originals: [Int: Annotation])
        case resize(SelectionHandle, index: Int, original: Annotation)
        case end(Int, index: Int, original: Annotation)
    }
    private var editDrag: EditDrag?
    /// 点在一组里的哪一个、真的拖动了没有：只点不拖 = 改成只选这一个
    private var editClicked: Int?
    private var editMoved = false
    /// ⇧ 按在已经选上的那个上：没拖就松手 = 把它去掉
    private var shiftToggleOff: Int?
    /// ⇧ 在空白处拖出来的框（台阶 19）从哪拖起
    private var bandStart: CGPoint?
    var isBandSelecting: Bool { bandStart != nil }
    var isDraggingSelection: Bool { editDrag != nil }

    /// 选区（视图坐标）。改了以后画布裁剪和工具栏位置跟着变
    var selection: CGRect = .zero {
        didSet {
            canvas.clipRect = selection
            layoutToolbar()
        }
    }

    /// 整个框挪动：只在画第一笔之前（台阶 20 拍板：画好以后在框里拖多半是想拖标注、画新的，整框挪动容易误碰）
    var canAdjustSelection: Bool { document.items.isEmpty && textView == nil && pending == nil }
    /// 拖边和角改框的大小：画了以后也行（台阶 20）。标注记在整块屏幕上、完成时才按框裁，框变了标注不用动
    var canResizeSelection: Bool { textView == nil && pending == nil }
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
        toolbar.onClear = { [weak self] in self?.clearAll() }
        toolbar.onFront = { [weak self] in self?.bringSelectedToFront() }
        toolbar.onBack = { [weak self] in self?.sendSelectedToBack() }
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

    /// 选中了画好的东西时，改的是它们（同时记成下次画的默认）；好几个一起改只算一步撤销
    func setColor(_ c: AnnotationColor, remember: Bool = false) {
        color = c
        if remember { Settings.annotationColorIndex = c.rawValue }
        if let tv = textView {
            styleTextView(tv)
        } else if hasSelection {
            document.replace(changesForSelected { $0.color = c })
        }
        refresh()
    }

    /// 选中的每一个改成什么样
    private func changesForSelected(_ change: (inout Annotation) -> Void) -> [Int: Annotation] {
        var changes: [Int: Annotation] = [:]
        for i in selectedIndices where document.items.indices.contains(i) {
            var a = document.items[i]
            change(&a)
            changes[i] = a
        }
        return changes
    }

    func setSize(_ s: AnnotationSize, remember: Bool = false) {
        size = s
        if remember { Settings.annotationSizeIndex = s.rawValue }
        if let tv = textView {
            styleTextView(tv)
            resizeTextView()
        } else if hasSelection {
            document.replace(changesForSelected { $0.size = s })
        }
        refresh()
    }

    func undo() {
        guard !isEditingText else { return }
        document.undo()
        selectedIndices = []
        refresh()
    }

    func redo() {
        guard !isEditingText else { return }
        document.redo()
        selectedIndices = []
        refresh()
    }

    /// 文档从外面整个换过（屏幕画笔收起时清空、连撤销记录也清掉）：重画一遍
    func reloadFromDocument() {
        selectedIndices = []
        refresh()
    }

    /// 清空画的（屏幕画笔，台阶 16）
    func clearAll() {
        commitText()
        selectedIndices = []
        document.removeAll()
        refresh()
    }

    // MARK: 选中画好的东西（台阶 12）

    /// 鼠标点在哪一条上（叠在一起取最上面的）
    func hitIndex(at p: CGPoint) -> Int? {
        document.items.indices.last { document.items[$0].hit(p) }
    }

    /// 按在选上的那几个的虚线框里（不一定在线上）也算抓住它们（2026-11-06 验收：拖不动——框、圈、笔画只认线，
    /// 按在框中间抓不住）。选了好几个时总是这样；只选一个时要没拿着工具（拿着工具在刚画的框里按 = 接着画新的）
    func grabIndex(at p: CGPoint) -> Int? {
        guard selectedIndices.count > 1 || (tool == nil && hasSelection) else { return nil }
        return selectedIndices.reversed().first { document.items.indices.contains($0)
            && document.items[$0].frame.insetBy(dx: -4, dy: -4).contains(p) }
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

    /// 鼠标按下：点在选中那个的小方块上 = 改大小 / 拖箭头一头；点在画好的东西上 = 选中它、准备挪
    /// （点在已经选上的一组里 = 整组一起挪）。duplicate（按住 ⌥）：拖出来的是复制的一份，原来的不动（台阶 19）。
    /// 返回 false = 什么都没点中，交给"画新的"
    @discardableResult
    func beginEdit(at p: CGPoint, duplicate: Bool = false) -> Bool {
        if !duplicate, let i = selectedIndex, document.items.indices.contains(i), let hit = handle(at: p, of: document.items[i]) {
            let original = document.items[i]
            if let h = hit.0 { editDrag = .resize(h, index: i, original: original) }
            else if let end = hit.1 { editDrag = .end(end, index: i, original: original) }
            document.beginLive()
            return true
        }
        guard let i = hitIndex(at: p) ?? grabIndex(at: p) else { return false }
        var group = IndexSet(integer: i)
        editMoved = false
        editClicked = nil
        shiftToggleOff = nil
        if selectedIndices.contains(i) {
            commitText()
            group = selectedIndices
            if !duplicate && group.count > 1 { editClicked = i }
        } else {
            select(i)
        }
        document.beginLive()
        if duplicate {
            group = document.duplicateLive(group)
            selectedIndices = group
            refresh()
        }
        editDrag = .move(start: p, originals: Dictionary(uniqueKeysWithValues: group.map { ($0, document.items[$0]) }))
        (duplicate ? NSCursor.dragCopy : NSCursor.closedHand).set()
        return true
    }

    func dragEdit(to p: CGPoint) {
        guard let editDrag else { return }
        switch editDrag {
        case .move(let start, let originals):
            let d = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            if d.dx != 0 || d.dy != 0 { editMoved = true }
            for (i, a) in originals { document.updateLive(at: i, with: a.moved(by: d)) }
        case .resize(let h, let i, let original):
            // 小方块画在外框外面 4 点，拖的时候换回到外框上，免得一按下去就跳一下
            let q = CGPoint(x: p.x + (h.movesLeft ? 4 : h.movesRight ? -4 : 0), y: p.y + (h.movesBottom ? 4 : h.movesTop ? -4 : 0))
            document.updateLive(at: i, with: original.resized(h, to: q, within: selection.isEmpty ? .infinite : selection))
        case .end(let end, let i, let original):
            document.updateLive(at: i, with: original.withEnd(end, at: p))
        }
        refresh()
    }

    func endEdit(at p: CGPoint) {
        guard editDrag != nil else { return }
        dragEdit(to: p)
        editDrag = nil
        document.endLive()
        if let clicked = editClicked, !editMoved { select(clicked) }     // 选着一组时只点了其中一个：只选它
        if let off = shiftToggleOff, !editMoved { selectedIndices.remove(off) }   // ⇧ 点已经选上的：去掉
        editClicked = nil
        shiftToggleOff = nil
        refresh()
    }

    func select(_ index: Int?) {
        commitText()
        selectedIndices = index.map { IndexSet(integer: $0) } ?? []
        if let index, document.items.indices.contains(index) { showProperties(of: index) }
        refresh()
    }

    /// 工具栏显示它的颜色、粗细（不记成默认，免得只是点一下就改了下次画的样子）
    private func showProperties(of index: Int) {
        color = document.items[index].color
        size = document.items[index].size
    }

    func deselect() {
        guard hasSelection else { return }
        selectedIndices = []
        refresh()
    }

    // MARK: 一次选好几个、复制、上下层（台阶 19）

    /// ⇧ 按在画好的东西上：没选上的先加进来；按着拖 = 选上的一起挪（2026-11-06 验收：框选完还按着 ⇧ 拖，拖不动）；
    /// 没拖就松手 = 点一下：原来就选上的去掉。没按在东西上返回 false（交给框选）
    @discardableResult
    func beginShiftPress(at p: CGPoint) -> Bool {
        guard let i = hitIndex(at: p) ?? grabIndex(at: p) else { return false }
        commitText()
        let wasSelected = selectedIndices.contains(i)
        if !wasSelected {
            selectedIndices.insert(i)
            showProperties(of: i)
        }
        editMoved = false
        editClicked = nil
        shiftToggleOff = wasSelected ? i : nil
        document.beginLive()
        editDrag = .move(start: p, originals: Dictionary(uniqueKeysWithValues: selectedIndices.map { ($0, document.items[$0]) }))
        refresh()
        return true
    }

    /// ⇧ 在空白处拖：框碰到的就是选上的（不算刚画完自动选着的那个；想再加就 ⇧ 点）
    func beginBand(at p: CGPoint) {
        commitText()
        bandStart = p
        canvas.bandRect = CGRect(origin: p, size: .zero)
    }

    func dragBand(to p: CGPoint) {
        guard let start = bandStart else { return }
        let band = Geometry.rect(from: start, to: p)
        canvas.bandRect = band
        selectedIndices = indices(touching: band)
        refresh()
    }

    func endBand(at p: CGPoint) {
        guard bandStart != nil else { return }
        dragBand(to: p)
        bandStart = nil
        canvas.bandRect = nil
        if let last = selectedIndices.last { showProperties(of: last) }
        refresh()
    }

    /// 外框和这个框碰到的
    func indices(touching band: CGRect) -> IndexSet {
        IndexSet(document.items.indices.filter { band.intersects(document.items[$0].frame.insetBy(dx: -1, dy: -1)) })
    }

    @discardableResult
    func selectAll() -> Bool {
        guard !isEditingText, !document.items.isEmpty else { return false }
        selectedIndices = IndexSet(document.items.indices)
        refresh()
        return true
    }

    /// ⌘D：复制一份，往右下错开 10 点；新的那份选中
    @discardableResult
    func duplicateSelected() -> Bool {
        guard !isEditingText, hasSelection else { return false }
        selectedIndices = document.duplicate(selectedIndices, offset: CGVector(dx: 10, dy: -10))
        refresh()
        return true
    }

    @discardableResult
    func bringSelectedToFront() -> Bool {
        guard !isEditingText, hasSelection else { return false }
        selectedIndices = document.bringToFront(selectedIndices)
        refresh()
        return true
    }

    @discardableResult
    func sendSelectedToBack() -> Bool {
        guard !isEditingText, hasSelection else { return false }
        selectedIndices = document.sendToBack(selectedIndices)
        refresh()
        return true
    }

    /// ⌘A 全选、⌘D 复制一份、⌘] 放到最上、⌘[ 放到最下（按键位认，中文输入法下也一样）。
    /// 打字时不管（⌘A 留给文字）；返回 true = 这个键归标注管（没选东西时也吞掉，免得"嘟"一声）
    func handleArrangeKey(_ keyCode: UInt16) -> Bool {
        guard !isEditingText else { return false }
        switch keyCode {
        case 0: selectAll()
        case 2: duplicateSelected()
        case 30: bringSelectedToFront()
        case 33: sendSelectedToBack()
        default: return false
        }
        return true
    }

    /// ⌫ / Delete：删掉选中的（好几个一起删只算一步）
    @discardableResult
    func deleteSelected() -> Bool {
        guard !isEditingText, hasSelection else { return false }
        document.remove(selectedIndices)
        selectedIndices = []
        refresh()
        return true
    }

    /// 方向键：选中的一起挪 1 点
    @discardableResult
    func nudgeSelected(by d: CGVector) -> Bool {
        guard !isEditingText, hasSelection else { return false }
        document.replace(changesForSelected { $0 = $0.moved(by: d) })
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
        if hitIndex(at: p) != nil { return .pointingHand }
        return grabIndex(at: p) != nil ? .openHand : nil                         // 选上的虚线框里：能抓住拖
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
        selectedIndices = []
        switch tool {
        case .text:
            if !editText(at: p) { startText(at: p) }
        case .number:
            document.add(Annotation(tool: .number, color: color, size: size, points: [p], number: document.nextNumber))
            selectedIndices = [document.items.count - 1]              // 放好就选中，马上能挪
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
            selectedIndices = [document.items.count - 1]              // 画完保持选中，马上能调（拍板）
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
        selectedIndices = []
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
        tv.font = AnnotationText.font(size, big: bigText)
        tv.textColor = color.nsColor
        tv.insertionPointColor = color.nsColor
        tv.typingAttributes = AnnotationText.attributes(color: color, size: size, big: bigText)
        tv.drawsBackground = true
        tv.backgroundColor = light ? NSColor.black.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.6)
        tv.layer?.borderColor = (light ? NSColor.white : NSColor.black).withAlphaComponent(0.5).cgColor
    }

    private func resizeTextView() {
        guard let tv = textView else { return }
        let s = AnnotationText.size(of: tv.string, color: color, size: size, big: bigText)
        let caret = size.fontSize(big: bigText) * 0.6        // 给光标和下一个字留点地方
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
        var a = Annotation(tool: .text, color: color, size: size, points: [textTopLeft], text: tv.string)
        a.bigText = bigText
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
        selectedIndices = selectedIndices.filteredIndexSet { document.items.indices.contains($0) }
        if let i = selectedIndex, textView == nil {
            let a = document.items[i]
            canvas.selectionLook = .init(frame: a.frame, handles: handlePoints(of: a).map(\.2), round: a.handles == .ends)
        } else {
            canvas.selectionLook = nil
        }
        // 选了好几个：每个一圈虚线框，不显示改大小的小方块（一起缩放不做）
        canvas.groupFrames = textView == nil && selectedIndices.count > 1 ? selectedIndices.map { document.items[$0].frame } : []
        toolbar.update(tool: tool, color: color, size: size, canUndo: document.canUndo, canRedo: document.canRedo,
                       showProperties: tool != nil || hasSelection, showArrange: hasSelection && textView == nil)
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

