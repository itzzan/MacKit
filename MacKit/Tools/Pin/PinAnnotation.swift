import AppKit

/// 在一张贴图上标注。
///
/// 贴图里放一块画板：画板的"坐标"就是原图大小（点），显示时跟着贴图当前的缩放比例放大缩小，
/// 所以缩放过的贴图也能标，鼠标位置自动换算回原图。
/// 工具栏放在挂在贴图下方的透明小窗口里：贴图可能比工具栏还窄。
@MainActor
final class PinAnnotationSession {
    private weak var pin: PinWindow?
    private let container: NSView
    let input: PinAnnotateView
    let editor: AnnotationEditor
    private var toolbarPanel: NSPanel?
    private let checkpoint: AnnotationDocument.Checkpoint
    private let present: Bool

    init(pin: PinWindow, present: Bool) {
        self.pin = pin
        self.present = present
        let base = CGRect(origin: .zero, size: pin.basePointSize)
        let content = pin.contentView ?? NSView(frame: CGRect(origin: .zero, size: pin.frame.size))
        container = NSView(frame: content.bounds)
        container.autoresizingMask = [.width, .height]
        container.bounds = base                              // 按原图大小画
        input = PinAnnotateView(frame: base)
        input.autoresizingMask = [.width, .height]
        container.addSubview(input)
        checkpoint = pin.document.checkpoint()               // Esc 时退回这里
        editor = AnnotationEditor(container: container,
                                  mosaic: MosaicSource(image: pin.originalImage, viewSize: pin.basePointSize),
                                  document: pin.document,
                                  customToolbar: AnnotationToolbar(mode: .pin, standalone: true),
                                  embedsToolbar: false)
        editor.selection = base
        editor.keyView = input
        input.editor = editor
        editor.onDone = { [weak self] in self?.finish() }
        editor.onCancel = { [weak self] in self?.discard() }
        editor.onToolbarChange = { [weak self] in self?.layoutToolbar() }
        content.addSubview(container)
    }

    func begin() {
        guard let pin else { return }
        pin.showOriginalWhileAnnotating(true)
        if present {
            let panel = makeToolbarPanel(level: pin.level, behavior: pin.collectionBehavior)
            toolbarPanel = panel
            pin.addChildWindow(panel, ordered: .above)       // 跟着贴图走
            layoutToolbar()
            NSApp.activate(ignoringOtherApps: true)          // 中文输入法要 MacKit 是当前软件
            pin.makeKeyAndOrderFront(nil)
        }
        pin.makeFirstResponder(input)
        Log.app.notice("pin annotate: begin, \(pin.document.items.count) existing")
    }

    /// 回车 / ✓：标注留在贴图上
    func finish() {
        editor.commitText()
        Log.app.notice("pin annotate: done, \(self.editor.document.items.count) items")
        end()
    }

    /// Esc / ✕：放弃这一次画的（连撤销记录一起退回进标注之前）
    func discard() {
        editor.commitText()
        editor.document.restore(checkpoint)
        Log.app.notice("pin annotate: discarded")
        end()
    }

    private func end() {
        guard let pin else { return }
        editor.tearDown()
        container.removeFromSuperview()
        if let panel = toolbarPanel {
            pin.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        toolbarPanel = nil
        pin.showOriginalWhileAnnotating(false)
        pin.annotationSessionEnded()
        // 把焦点还给之前在用的软件（贴图 canHide = false，不会跟着藏）
        if present, NSApp.modalWindow == nil { NSApp.hide(nil) }
    }

    private func makeToolbarPanel(level: NSWindow.Level, behavior: NSWindow.CollectionBehavior) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: editor.toolbar.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.collectionBehavior = behavior
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true                  // 点工具栏按钮不抢走贴图的键盘焦点
        panel.animationBehavior = .none
        panel.contentView = editor.toolbar
        return panel
    }

    /// 工具栏放在贴图下方、右对齐；下面放不下就放上面
    private func layoutToolbar() {
        guard let pin, let panel = toolbarPanel else { return }
        let size = editor.toolbar.frame.size
        let visible = (pin.screen ?? NSScreen.main)?.visibleFrame ?? pin.frame.insetBy(dx: -2000, dy: -2000)
        let origin = EditGeometry.toolbarOrigin(size: size, selection: pin.frame, bounds: visible)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// 贴图标注时盖在贴图上的那层：接鼠标键盘，交给标注编辑器。坐标是原图大小（点）
@MainActor
final class PinAnnotateView: NSView {
    weak var editor: AnnotationEditor?
    /// 滚轮交给外面能滚的视图（长截图标注，台阶 20）；贴图上标注时不滚、不缩放
    var passesScrollWheel = false
    /// 屏幕画笔先看一眼的按键（台阶 22：Z 开关放大镜、放大镜开着时 Esc 先收放大镜）；返回 true = 已经处理了
    var interceptKey: ((NSEvent) -> Bool)?
    /// 屏幕画笔的滚轮（放大镜调倍数）
    var onScroll: ((NSEvent) -> Void)?
    private var drawing = false
    private var editing = false                 // 拖选中的标注（台阶 12）
    private var banding = false                 // ⇧ 在空白处拖：框选（台阶 19）
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard let editor else { return .arrow }
        if let tv = editor.textView, tv.frame.contains(p) { return .iBeam }
        if let c = editor.editCursor(at: p) { return c }
        if (editor.tool == nil || editor.tool == .text), editor.document.textIndex(at: p) != nil { return .iBeam }
        guard let tool = editor.tool else { return .arrow }
        return tool == .text ? .iBeam : .crosshair
    }

    override func cursorUpdate(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }
    override func mouseMoved(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        drawing = false
        editing = false
        banding = false
        if editor.isEditingText {                                    // 点别处 = 打完字
            editor.commitText()
        } else if event.clickCount >= 2, editor.document.textIndex(at: p) != nil {
            editor.editText(at: p)                                   // 双击文字 = 接着改
        } else if event.modifierFlags.contains(.shift), !editor.document.items.isEmpty {
            // ⇧ 点画好的东西 = 加选 / 去掉；⇧ 在空白处拖 = 框选（台阶 19）
            if editor.beginShiftPress(at: p) { editing = true } else { editor.beginBand(at: p); banding = true }
        } else if !(editor.tool == .text && editor.document.textIndex(at: p) != nil),
                  editor.beginEdit(at: p, duplicate: event.modifierFlags.contains(.option)) {
            editing = true                                           // 点中画好的东西：选中它，拖它
        } else if let tool = editor.tool, bounds.contains(p) {
            editor.mouseDown(at: p)
            drawing = !tool.isClickTool
        } else {
            editor.deselect()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        if editing { editor.dragEdit(to: p) } else if banding { editor.dragBand(to: p) } else if drawing { editor.mouseDragged(to: p) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        if editing {
            editing = false
            editor.endEdit(at: p)
            cursor(at: p).set()
        } else if banding {
            banding = false
            editor.endBand(at: p)
        } else if drawing {
            drawing = false
            editor.mouseUp(at: p)
        }
    }

    // 标注时不拖动、不缩放、不弹右键菜单，免得画歪
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {
        if passesScrollWheel { super.scrollWheel(with: event) } else { onScroll?(event) }
    }
    override func magnify(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
        if interceptKey?(event) == true { return }
        let code = Int(event.keyCode)
        if code == 53 {                                              // Esc：有选中的先取消选中，没有就放弃这次画的
            if editor.hasSelection { editor.deselect() } else { editor.onCancel?() }
            return
        }
        if code == 51 || code == 117 { editor.deleteSelected(); return }   // ⌫ / Delete：删掉选中的
        let arrows: [Int: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                       125: CGVector(dx: 0, dy: -1), 126: CGVector(dx: 0, dy: 1)]
        if let d = arrows[code], editor.nudgeSelected(by: d) { return }
        if code == 36 || code == 76 { editor.onDone?(); return }     // 回车：完成
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = AnnotationTool.forKey(key) {
            editor.selectTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, editor.handleArrangeKey(event.keyCode) { return true }    // ⌘A ⌘D ⌘] ⌘[（台阶 19）
        guard mods.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, mods.contains(.shift)) {
        case ("z", false) where !editor.isEditingText: editor.undo()
        case ("z", true) where !editor.isEditingText: editor.redo()
        case ("w", _), ("c", _), ("s", _), ("0", _): break           // 标注中不关贴图、不复制，先完成再说
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
