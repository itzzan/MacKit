import AppKit
import UniformTypeIdentifiers

struct SelectionResult {
    let image: CGImage
    let pointSize: NSSize
    let globalFrame: CGRect          // 截取的区域在屏幕上的位置（Cocoa 全局坐标，点），贴图贴回原位用
}

/// 一次截图的结局
enum SelectionOutcome {
    case copy(SelectionResult)       // 完成：复制并保存
    case pin(SelectionResult)        // 钉成贴图
    case saved(URL)                  // 另存为
    case cancelled
}

/// 能拿到键盘焦点的无边框窗口（不然收不到 Esc）
final class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeys.handle(event, firstResponder: firstResponder) || super.performKeyEquivalent(with: event)
    }
}

/// MacKit 没有"编辑"菜单，打字时 ⌘V/⌘C/⌘X/⌘A/⌘Z 要自己转给文本框
@MainActor
enum TextEditingKeys {
    static func handle(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let tv = firstResponder as? NSTextView, mods.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch (key, mods.contains(.shift)) {
        case ("v", _): tv.paste(nil)
        case ("c", _): tv.copy(nil)
        case ("x", _): tv.cut(nil)
        case ("a", _): tv.selectAll(nil)
        case ("z", false): tv.undoManager?.undo()
        case ("z", true): tv.undoManager?.redo()
        default: return false
        }
        return true
    }
}

/// 一次截图：每块屏幕一个覆盖层。框定后进入标注编辑，最后复制、贴图、另存或取消
@MainActor
final class SelectionSession {
    /// 正在进行的截图（贴图快捷键 ⌘2 要知道现在是不是在编辑）
    private(set) static weak var active: SelectionSession?

    var onFinish: ((SelectionOutcome) -> Void)?

    private struct ScreenUI {
        let frozen: FrozenScreen
        let overlay: OverlayWindow
        let container: NSView
        let view: SelectionView
    }

    private let screens: [FrozenScreen]
    private let windowFrames: [CGRect]
    private let quickMode: Bool
    private var ui: [ScreenUI] = []
    private var editing: (screen: ScreenUI, editor: AnnotationEditor, mosaic: MosaicSource)?
    /// 保存窗口开着：这期间 ⌘2、Esc、完成都不响应
    private(set) var isSaving = false

    var isEditing: Bool { editing != nil }

    init(screens: [FrozenScreen], windowFrames: [CGRect], quickMode: Bool) {
        self.screens = screens
        self.windowFrames = windowFrames
        self.quickMode = quickMode
    }

    func begin() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        var keyIndex = 0

        for (index, frozen) in screens.enumerated() {
            let frame = frozen.screen.frame
            let rects = Geometry.viewRects(forCGWindowFrames: windowFrames, screenFrame: frame,
                                           primaryHeight: primaryHeight)
            let bounds = NSRect(origin: .zero, size: frame.size)
            let container = NSView(frame: bounds)
            container.wantsLayer = true
            let view = SelectionView(frame: bounds, image: frozen.image, windowRects: rects,
                                     scale: frozen.screen.backingScaleFactor)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)

            view.onSelect = { [weak self] rect in self?.selected(rect, onScreen: index) }
            view.onCancel = { [weak self] in self?.cancel() }
            view.onDone = { [weak self] in self?.finishCopy() }
            view.onSave = { [weak self] in self?.saveAs() }

            let overlay = OverlayWindow(frame: frame)
            overlay.contentView = container
            ui.append(ScreenUI(frozen: frozen, overlay: overlay, container: container, view: view))
            if NSMouseInRect(mouse, frame, false) { keyIndex = index }
        }

        Self.active = self
        NSApp.activate(ignoringOtherApps: true)
        for screen in ui { screen.overlay.orderFrontRegardless() }
        if ui.indices.contains(keyIndex) {
            ui[keyIndex].overlay.makeKey()
            ui[keyIndex].overlay.makeFirstResponder(ui[keyIndex].view)
        }
        for screen in ui { screen.view.refreshHover(globalMouse: mouse) }
        NSCursor.crosshair.set()
    }

    // MARK: 框定之后

    private func selected(_ rect: CGRect, onScreen index: Int) {
        guard ui.indices.contains(index), editing == nil else { return }
        let screen = ui[index]
        if quickMode {
            if let result = Self.crop(image: screen.frozen.image, viewSize: screen.view.bounds.size, rect: rect,
                                      screenOrigin: screen.frozen.screen.frame.origin) {
                end(.copy(result))
            } else {
                end(.cancelled)
            }
            return
        }
        let mosaic = MosaicSource(image: screen.frozen.image, viewSize: screen.view.bounds.size)
        let editor = AnnotationEditor(container: screen.container, mosaic: mosaic)
        editor.onDone = { [weak self] in self?.finishCopy() }
        editor.onPin = { [weak self] in self?.finishPin() }
        editor.onSave = { [weak self] in self?.saveAs() }
        editor.onCancel = { [weak self] in self?.cancel() }
        editing = (screen, editor, mosaic)
        screen.view.beginEditing(editor, selection: rect)
        for other in ui where other.view !== screen.view { other.view.goIdle() }
        screen.overlay.makeKey()
        screen.overlay.makeFirstResponder(screen.view)
    }

    /// 冻住的画面 + 标注 → 最终图片
    private func export() -> SelectionResult? {
        guard let editing, let rect = editing.screen.view.currentSelection else { return nil }
        editing.editor.commitText()
        return AnnotationExporter.export(image: editing.screen.frozen.image,
                                         viewSize: editing.screen.view.bounds.size, selection: rect,
                                         screenOrigin: editing.screen.frozen.screen.frame.origin,
                                         annotations: editing.editor.document.items, mosaic: editing.mosaic)
    }

    func finishCopy() {
        guard !isSaving else { return }
        guard let result = export() else { end(.cancelled); return }
        end(.copy(result))
    }

    /// 贴图快捷键或📌按钮
    func finishPin() {
        guard !isSaving else { return }
        guard let result = export() else { end(.cancelled); return }
        end(.pin(result))
    }

    func cancel() {
        guard !isSaving else { return }
        end(.cancelled)
    }

    /// 另存为。
    /// 2026-11-04 的教训：系统保存窗口是另一个进程画的，压不过冻住的画面（屏保层级），
    /// 用 runModal 等一个看不见的窗口会把 MacKit 整个卡死。所以：
    /// 先把冻住的画面收起来 → 用不卡人的方式打开保存窗口 → 存好就结束；点取消就把画面原样放回来接着编辑。
    func saveAs() {
        guard !isSaving, let result = export(),
              let png = ImageOutput.pngData(of: result.image, pointSize: result.pointSize) else { return }
        isSaving = true
        for screen in ui { screen.overlay.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.saveFolder
        panel.nameFieldStringValue = "MacKit_\(Self.timestamp()).png"
        Log.capture.notice("save panel opened, overlays hidden")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSaving = false
                guard response == .OK, let url = panel.url else {
                    Log.capture.notice("save panel cancelled, back to editing")
                    self.resumeEditing()
                    return
                }
                do {
                    try png.write(to: url, options: .atomic)
                    self.end(.saved(url))
                } catch {
                    Toast.show("保存失败：\(error.localizedDescription)", seconds: 3)
                    self.resumeEditing()
                }
            }
        }
    }

    /// 把冻住的画面和标注原样放回来
    private func resumeEditing() {
        guard !ui.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for screen in ui { screen.overlay.orderFrontRegardless() }
        if let editing {
            editing.screen.overlay.makeKey()
            editing.screen.overlay.makeFirstResponder(editing.screen.view)
        }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// 从冻住的整屏图里裁出选中的部分（快速模式、自检用）
    static func crop(image: CGImage, viewSize: CGSize, rect: CGRect, screenOrigin: CGPoint) -> SelectionResult? {
        AnnotationExporter.export(image: image, viewSize: viewSize, selection: rect, screenOrigin: screenOrigin,
                                  annotations: [], mosaic: nil)
    }

    private func end(_ outcome: SelectionOutcome) {
        guard !ui.isEmpty else { return }
        editing?.editor.tearDown()
        editing = nil
        for screen in ui { screen.overlay.orderOut(nil) }
        ui.removeAll()
        if Self.active === self { Self.active = nil }
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
        // 把焦点还给截图前在用的软件。有对话框开着时不能藏，否则对话框跟着藏起来，MacKit 就卡在那里了
        if NSApp.modalWindow == nil { NSApp.hide(nil) }
    }
}
