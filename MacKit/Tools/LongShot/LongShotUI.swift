import AppKit

/// 长截图时框下面的小控制条：进度文字、⬇ 自动滚动、✕ 取消、✓ 完成
@MainActor
final class LongShotControlBar {
    var onAuto: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    private(set) var autoButton: ToolbarButton!
    private(set) var doneButton: ToolbarButton!
    private(set) var isWarning = false

    static let startText = "往下或往右滚，MacKit 边看边拼　·　回车完成　·　Esc 取消"
    /// 认出来往哪个方向拼（台阶 25）：自动滚动的图标、提示跟着变
    private(set) var axis: LongShotAxis = .vertical

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.canHide = false                         // 选完区域 MacKit 会藏起来交还焦点，控制条要留着
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        label.font = Theme.body()
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        autoButton = ToolbarButton(symbol: "arrow.down.circle", title: "自动滚动", tip: "MacKit 替你往下滚，到底自动停",
                                   width: 108) { [weak self] in self?.onAuto?() }
        let cancel = ToolbarButton(symbol: "xmark", tip: "取消（Esc）") { [weak self] in self?.onCancel?() }
        doneButton = ToolbarButton(symbol: "checkmark", title: "完成", tip: "完成：复制并保存（回车）", style: .primary) { [weak self] in
            self?.onDone?()
        }

        let row = Theme.row([label, autoButton, Theme.dividerView(), cancel, doneButton],
                            insets: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 6))
        panel.contentView = Theme.bar(containing: row)
        panel.setContentSize(row.fittingSize)
        setStatus(Self.startText)
    }

    func setStatus(_ text: String, warning: Bool = false) {
        label.stringValue = text
        label.textColor = warning ? Theme.warning : Theme.text
        isWarning = warning
    }

    func setAutoScrolling(_ on: Bool) {
        let idle = axis == .horizontal ? ("arrow.right.circle", "MacKit 替你往右滚，到头自动停") : ("arrow.down.circle", "MacKit 替你往下滚，到底自动停")
        autoButton.setSymbol(on ? "stop.circle" : idle.0, tip: on ? "停下来，自己滚" : idle.1)
        autoButton.setTitle(on ? "停止滚动" : "自动滚动")
    }

    /// 横着拼了：自动滚动换成往右
    func setAxis(_ a: LongShotAxis) {
        axis = a
        setAutoScrolling(false)
    }

    /// 放在框的下方、右对齐；下面放不下就放上面
    func show(near region: CGRect, on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? region
        let m = RecordingBorderWindow.margin
        panel.setFrameOrigin(EditGeometry.toolbarOrigin(size: panel.frame.size, selection: region.insetBy(dx: -m, dy: -m),
                                                        bounds: visible))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// 框旁边的预览条：拼好的长图缩小了竖着放，长了就露出最新拼上的那一截。
/// 横着拼时（台阶 25）换到框的上面横着放，最新拼上的在右边
@MainActor
final class LongShotPreview {
    static let width: CGFloat = 110
    static let horizontalHeight: CGFloat = 90
    let panel: NSPanel
    let view = LongShotThumbView()

    init(frame: CGRect) {
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    func update(_ thumb: CGImage) {
        view.image = thumb
        view.needsDisplay = true
    }

    /// 横着拼了：挪到 frame（框的上面），小图横着放
    func setHorizontal(frame: CGRect) {
        panel.setFrame(frame, display: true)
        view.horizontal = true
        view.needsDisplay = true
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}

final class LongShotThumbView: NSView {
    var image: CGImage?
    /// 横着拼：等高缩放，露出最右边
    var horizontal = false
    static let inset: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Theme.barRadius, cornerHeight: Theme.barRadius,
                           transform: nil)
        ctx.addPath(outer)
        ctx.setFillColor(Theme.solidFill.cgColor)
        ctx.fillPath()
        ctx.addPath(outer)
        ctx.setStrokeColor(Theme.border.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        let box = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        guard let image else {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.small(), .foregroundColor: Theme.secondaryText]
            ("预览" as NSString).draw(at: CGPoint(x: box.minX + 4, y: box.maxY - 18), withAttributes: attrs)
            return
        }
        let size = CGSize(width: image.width, height: image.height)
        let layout = horizontal ? LongShotGeometry.horizontalThumbLayout(thumbSize: size, box: box.size)
            : LongShotGeometry.thumbLayout(thumbSize: size, box: box.size)
        ctx.saveGState()
        ctx.clip(to: box)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: layout.offsetBy(dx: box.minX, dy: box.minY))
        ctx.restoreGState()
    }
}

/// 自动滚动：在框的正中间替你一小段一小段地滚滚轮（要"辅助功能"权限）。
/// 你一动鼠标就停，免得跟你抢
@MainActor
final class AutoScroller {
    static let interval: TimeInterval = 0.05
    /// 哪个方向是往下（合成的滚轮事件一般负数是往下；不对的话长截图会话会反过来，记住下次用）
    static var downSign: Int32 = -1
    /// 横着拼时哪个方向是往右（台阶 25，同样不对就反过来、记住）
    static var rightSign: Int32 = -1
    /// 往哪个方向滚：竖着用滚轮的上下那一路，横着用左右那一路
    let axis: LongShotAxis
    private(set) var isRunning = false
    private var timer: Timer?
    /// 框的中心：CG 全局坐标（左上原点），发事件用
    let point: CGPoint
    /// 框的中心：Cocoa 全局坐标，看鼠标有没有被你挪走
    let cocoaPoint: CGPoint
    /// 每次滚多少点
    let step: Int32
    var onMouseMoved: (() -> Void)?

    init(region: CGRect, axis: LongShotAxis = .vertical) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? region.maxY
        cocoaPoint = CGPoint(x: region.midX, y: region.midY)
        point = CGPoint(x: region.midX, y: primaryHeight - region.midY)
        self.axis = axis
        let length = axis == .horizontal ? region.width : region.height
        step = Int32(max(4, min(80, length * 0.06)))              // 大约每秒滚 1.2 个框高（横着是框宽）
    }

    /// 每一下发的滚轮：(上下那一路, 左右那一路)（自检看这个，不真发）
    var wheels: (vertical: Int32, horizontal: Int32) {
        axis == .horizontal ? (0, Self.rightSign * step) : (Self.downSign * step, 0)
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        CGWarpMouseCursorPosition(point)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func flipDirection() {
        if axis == .horizontal { Self.rightSign = -Self.rightSign } else { Self.downSign = -Self.downSign }
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        if hypot(m.x - cocoaPoint.x, m.y - cocoaPoint.y) > 40 {
            stop()
            onMouseMoved?()
            return
        }
        let w = wheels
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: axis == .horizontal ? 2 : 1,
                            wheel1: w.vertical, wheel2: w.horizontal, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }
}
