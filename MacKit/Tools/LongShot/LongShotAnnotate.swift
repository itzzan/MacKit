import AppKit

/// 长截图上标注（台阶 20）：长图放在能上下滚的窗口里，上面盖一层和贴图标注同一套的编辑器
/// （台阶 19 的 ⇧ 框选、⌘D、上下层也都在）。完成（回车）= 带标注的那张复制 + 另存一张新的 PNG，
/// 原来没标注的那张留着（拍板）；取消（Esc）= 不要这次画的
@MainActor
final class LongShotAnnotateWindow: NSObject, NSWindowDelegate {
    let window: EditableWindow
    let image: CGImage
    let pointSize: CGSize
    let editor: AnnotationEditor
    let input: PinAnnotateView
    let scrollView = NSScrollView()
    private let mosaic: MosaicSource
    private let document: NSView
    private var finished = false
    /// 完成：带标注的长图、它的大小（点）
    var onDone: ((CGImage, CGSize) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, pointSize: CGSize) {
        self.image = image
        self.pointSize = pointSize
        let bounds = CGRect(origin: .zero, size: pointSize)
        document = NSView(frame: bounds)
        let picture = NSImageView(frame: bounds)
        picture.image = NSImage(cgImage: image, size: pointSize)
        picture.imageScaling = .scaleAxesIndependently
        document.addSubview(picture)
        input = PinAnnotateView(frame: bounds)
        input.passesScrollWheel = true                       // 滚轮照样上下滚长图
        document.addSubview(input)
        mosaic = MosaicSource(image: image, viewSize: pointSize)
        editor = AnnotationEditor(container: document, mosaic: mosaic,
                                  customToolbar: AnnotationToolbar(mode: .pin, standalone: false), embedsToolbar: false)
        editor.selection = bounds
        editor.keyView = input
        input.editor = editor

        // 窗口宽按长图宽（太宽就缩到屏幕宽的九成，左右也能滚），高按屏幕可见高度
        let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let barHeight = Self.barHeight(for: editor.toolbar)
        let width = min(max(pointSize.width, editor.toolbar.frame.width + 24), (visible.width * 0.9).rounded())
        let height = min(pointSize.height + barHeight, (visible.height * 0.9).rounded())
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "长截图标注　\(image.width)×\(image.height)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: min(width, 420), height: min(height, 300))

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = pointSize.width > width
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        content.addSubview(scrollView)
        content.addSubview(editor.toolbar)
        window.contentView = content

        editor.onDone = { [weak self] in self?.finish() }
        editor.onCancel = { [weak self] in self?.window.close() }
        editor.onToolbarChange = { [weak self] in self?.layout() }
        layout()
        scrollToTop()
    }

    /// 工具栏那条有多高（选了工具会多出一排颜色粗细）
    private static func barHeight(for toolbar: AnnotationToolbar) -> CGFloat { toolbar.frame.height + 12 }

    /// 工具栏贴在窗口最上面，下面全是能滚的长图
    private func layout() {
        guard let content = window.contentView else { return }
        let bar = Self.barHeight(for: editor.toolbar)
        editor.toolbar.setFrameOrigin(CGPoint(x: 8, y: content.bounds.height - bar + 6))
        scrollView.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: max(content.bounds.height - bar, 0))
    }

    /// 长图从最上面开始看（不翻转的视图里，原点在左下角，默认会停在最下面）
    func scrollToTop() {
        let top = max(document.frame.height - scrollView.contentSize.height, 0)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 现在看到的是长图的哪一段（点，左下原点）
    var visibleRect: CGRect { scrollView.contentView.documentVisibleRect }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    /// 带标注的长图（原图清晰度）
    func result() -> SelectionResult? {
        editor.commitText()
        return AnnotationExporter.export(image: image, viewSize: pointSize, selection: CGRect(origin: .zero, size: pointSize),
                                         screenOrigin: .zero, annotations: editor.document.items, mosaic: mosaic)
    }

    func finish() {
        guard !finished, let r = result() else { return }
        finished = true
        window.close()
        onDone?(r.image, r.pointSize)
    }

    func windowDidResize(_ notification: Notification) { layout() }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        editor.tearDown()
        onClose?()
        // 焦点还给原来的软件；还开着别的普通窗口就不藏，贴图本来就不跟着藏
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.canHide && $0.level == .normal }
        if NSApp.isActive, NSApp.modalWindow == nil, others.isEmpty { NSApp.hide(nil) }
    }
}
