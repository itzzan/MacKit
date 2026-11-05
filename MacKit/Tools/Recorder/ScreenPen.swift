import AppKit
import Carbon.HIToolbox

/// 屏幕画笔（台阶 16）：在屏幕的一块上直接画（录屏时录进视频；平时开会共享屏幕时圈重点）。
///
/// 画的那层是盖在那一块上的透明窗口：打开时接鼠标，收起时整个藏起来、画的一起清掉（拍板 A）。
/// 它和那排小工具都是"不激活"的浮动窗口：能收 Esc、⌘Z，又不会把你正在用的软件挤下去，菜单栏也不变
@MainActor
final class ScreenPenSession {
    let region: CGRect                       // 全局坐标（点）
    let overlay: ScreenPenPanel
    let toolbarPanel: NSPanel
    let editor: AnnotationEditor
    let input: PinAnnotateView
    private let present: Bool
    private(set) var isDrawing = false
    /// 打开 / 收起（录制小条上的按钮跟着亮）
    var onChange: ((Bool) -> Void)?

    /// present = false 只给自检用：不显示、不抢键盘
    init(region: CGRect, present: Bool = true) {
        self.region = region
        self.present = present
        overlay = ScreenPenPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .statusBar                 // 盖在软件上面，录制小条（更高一层）还在它上面
        overlay.canHide = false
        overlay.hidesOnDeactivate = false
        overlay.isReleasedWhenClosed = false
        overlay.becomesKeyOnlyIfNeeded = false
        overlay.animationBehavior = .none
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.acceptsMouseMovedEvents = true

        let bounds = CGRect(origin: .zero, size: region.size)
        let container = ScreenPenCatcherView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        input = PinAnnotateView(frame: bounds)
        input.autoresizingMask = [.width, .height]
        container.addSubview(input)
        overlay.contentView = container
        editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: Self.blankImage, viewSize: bounds.size),
                                  customToolbar: AnnotationToolbar(mode: .liveDraw, standalone: true), embedsToolbar: false)
        editor.selection = bounds
        editor.keyView = input
        input.editor = editor

        toolbarPanel = NSPanel(contentRect: CGRect(origin: .zero, size: editor.toolbar.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.hasShadow = true
        toolbarPanel.level = .popUpMenu
        toolbarPanel.canHide = false
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.isReleasedWhenClosed = false
        toolbarPanel.becomesKeyOnlyIfNeeded = true          // 点工具不抢走画布的键盘
        toolbarPanel.animationBehavior = .none
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        toolbarPanel.contentView = editor.toolbar

        editor.onDone = { [weak self] in self?.end() }
        editor.onCancel = { [weak self] in self?.end() }
        editor.onToolbarChange = { [weak self] in self?.layoutToolbar() }
        editor.selectTool(.pen)
    }

    /// 马赛克、模糊不在屏幕画笔里，打码那份画面用不上，给一张 1×1 的空图
    private static let blankImage: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    /// 那排小工具的窗口编号（录屏时列进"不录"名单）
    var toolbarWindowNumber: CGWindowID { CGWindowID(toolbarPanel.windowNumber) }

    func toggle() { isDrawing ? end() : begin() }

    /// takeKeyboard = false 只给实录检查用：画布显示出来，但不收键盘
    func begin(takeKeyboard: Bool = true) {
        guard !isDrawing else { return }
        isDrawing = true
        if editor.tool == nil { editor.selectTool(.pen) }
        // 2026-11-05 验收：鼠标没变十字、也画不了——全透明窗口的透明处，系统默认让点击穿过去给下面的软件。
        // 明确说"要接鼠标"，再配上几乎看不见的底色（ScreenPenCatcherView），点哪都落在画布上
        overlay.ignoresMouseEvents = false
        if present {
            overlay.orderFrontRegardless()
            if takeKeyboard {
                overlay.makeKey()                       // 不激活 MacKit，只让画布收键盘
                overlay.makeFirstResponder(input)
            }
            layoutToolbar()
            toolbarPanel.orderFrontRegardless()
            NSCursor.crosshair.set()
        }
        onChange?(true)
        Log.capture.notice("screen pen on")
    }

    /// 收起：画的一起清掉（拍板 A）
    func end() {
        guard isDrawing else { return }
        isDrawing = false
        editor.commitText()
        editor.document.restore(AnnotationDocument().checkpoint())     // 画的和撤销记录一起清掉
        editor.reloadFromDocument()
        overlay.orderOut(nil)
        toolbarPanel.orderOut(nil)
        onChange?(false)
        Log.capture.notice("screen pen off")
    }

    func close() {
        end()
        editor.tearDown()
    }

    /// 小工具放在画的那块下方、右对齐；下面放不下就放上面，都不行就放在里面
    private func layoutToolbar() {
        let size = editor.toolbar.frame.size
        let visible = (NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main)?.visibleFrame ?? region
        let origin = EditGeometry.toolbarOrigin(size: size, selection: region, bounds: visible)
        toolbarPanel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// 画布的底：涂一层几乎看不见的底色（黑色、透明度 1/255，屏幕上、视频里都看不出来），
/// 不然全透明的地方点击会穿过去，画不了
final class ScreenPenCatcherView: NSView {
    static let fill = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0 / 255)

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        dirtyRect.fill()
    }
}

/// 画布窗口：不激活 MacKit 也能当键盘窗口（收 Esc、⌘Z）
final class ScreenPenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 画笔快捷键 ⌃⇧D：只在录屏时、或开着屏幕画笔时注册
enum ScreenPenHotKey {
    /// 默认的 ⌃⇧D；设置窗口里能改（台阶 17），用的时候读 Settings.hotKey(.screenPen)
    static let standard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | shiftKey), display: "⌃⇧D",
                                   menuKey: "d", menuModifiers: [.control, .shift], note: "屏幕画笔")
}

/// 菜单"小工具 → 屏幕画笔"：不录屏时在鼠标所在的整块屏幕上画（拍板 A：平时也能用）
@MainActor
final class ScreenPenTool: ToolModule {
    private(set) var session: ScreenPenSession?
    private var hotKeyID: UInt32?
    /// 录屏忙着时用录制小条上的画笔（AppDelegate 里接上）
    var isRecordingBusy: () -> Bool = { false }

    func activate() {}

    var isOn: Bool { session?.isDrawing == true }

    func start(present: Bool = true) {
        guard !isRecordingBusy() else {
            Toast.show("录屏中：点录制小条上的\u{201C}画笔\u{201D}或按 ⌃⇧D")
            return
        }
        if let session { session.begin(); return }
        let screen = NSScreen.withMouse ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let s = ScreenPenSession(region: frame, present: present)
        s.onChange = { [weak self] on in if !on { self?.stop() } }
        session = s
        if present, let combo = Settings.hotKey(.screenPen) {
            hotKeyID = HotKeyCenter.shared.register(combo) { [weak self] in self?.stop() }
        }
        s.begin()
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = nil
        s.onChange = nil
        s.close()
    }

    func menuItems() -> [NSMenuItem] {
        if isOn {
            return [ActionMenuItem("收起屏幕画笔（⌃⇧D 或 Esc）") { [weak self] in self?.stop() }]
        }
        return [ActionMenuItem("屏幕画笔（在屏幕上圈圈画画，Esc 收起）") { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.15))            // 等菜单收起
                self?.start()
            }
        }]
    }
}
