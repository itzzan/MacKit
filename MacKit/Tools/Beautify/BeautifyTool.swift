import AppKit

/// 把美化样式画成图：背景（渐变或透明）→ 阴影 → 按圆角裁好的截图。原图不动（台阶 13）
enum BeautifyRenderer {
    /// 截图缩成 24×24，交给纯计算找主色
    static func autoGradient(of image: CGImage) -> BeautifyGradient {
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? BeautifyMath.autoGradient(rgba: bytes, width: side, height: side) : BeautifyMath.presets[0]
    }

    static func gradient(for background: BeautifyStyle.Background, auto: @autoclosure () -> BeautifyGradient) -> BeautifyGradient? {
        switch background {
        case .preset(let i): BeautifyMath.presets[min(max(i, 0), BeautifyMath.presets.count - 1)]
        case .auto: auto()
        case .none: nil
        case .solid(let c): BeautifyGradient(name: "自选", from: c.tuple, to: c.tuple)
        }
    }

    static func cgColor(_ c: (Double, Double, Double)) -> CGColor { CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1) }

    /// scale：每个点画几个像素（导出用截图本身的清晰度，预览用小一点的）
    static func render(_ image: CGImage, pointSize: CGSize, style: BeautifyStyle, scale: CGFloat,
                       autoGradient auto: BeautifyGradient? = nil) -> CGImage? {
        let (canvas, rect) = BeautifyMath.layout(imageSize: pointSize, style: style)
        let w = max(Int((canvas.width * scale).rounded()), 1), h = max(Int((canvas.height * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(w) / canvas.width, y: CGFloat(h) / canvas.height)
        if let g = gradient(for: style.background, auto: auto ?? autoGradient(of: image)),
           let grad = CGGradient(colorsSpace: space, colors: [cgColor(g.from), cgColor(g.to)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: canvas.width, y: canvas.height),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let radius = BeautifyMath.cornerRadius(for: pointSize, corner: style.corner)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow {
            let s = BeautifyMath.shadow(for: pointSize, padding: BeautifyMath.padding(for: pointSize, level: style.padding))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: s.offset), blur: s.blur,
                          color: NSColor.black.withAlphaComponent(style.background == .none ? 0.45 : 0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// "美化截图"窗口：左边预览，右边挑背景、留白、圆角、阴影；取消 / 钉成贴图 / 完成（回车）
@MainActor
final class BeautifyWindow: NSObject, NSWindowDelegate {
    let window: EditableWindow
    let source: CGImage
    let pointSize: CGSize
    private(set) var style: BeautifyStyle
    let preview = NSImageView()
    private(set) var swatches: [BeautifySwatch] = []
    let paddingControl = NSSegmentedControl(labels: ["小", "中", "大"], trackingMode: .selectOne, target: nil, action: nil)
    let cornerControl = NSSegmentedControl(labels: ["无", "小", "大"], trackingMode: .selectOne, target: nil, action: nil)
    let shadowBox = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    let ratioControl = NSSegmentedControl(labels: BeautifyStyle.Ratio.allCases.map(\.title), trackingMode: .selectOne,
                                          target: nil, action: nil)
    /// 最后那个"自选"色块：点了打开系统的取色盘（台阶 20）
    private(set) var customSwatch: BeautifySwatch!
    /// 取色盘现在是不是在给这个窗口送颜色
    private(set) var ownsColorPanel = false
    private(set) var buttons: [String: NSButton] = [:]
    private lazy var auto = BeautifyRenderer.autoGradient(of: source)
    /// 完成：复制 + 存（BeautifyTool 接上）
    var onDone: ((CGImage, CGSize) -> Void)?
    var onPin: ((CGImage, CGSize) -> Void)?
    var onClose: (() -> Void)?
    static let previewBox = CGSize(width: 620, height: 420)

    init(image: CGImage, pointSize: CGSize, style: BeautifyStyle) {
        source = image
        self.pointSize = pointSize
        self.style = style
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 500),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "美化截图"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        refresh()
    }

    private func build() {
        preview.imageScaling = .scaleProportionallyDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: Self.previewBox.width).isActive = true
        preview.heightAnchor.constraint(equalToConstant: Self.previewBox.height).isActive = true

        var backgrounds: [BeautifyStyle.Background] = BeautifyMath.presets.indices.map { .preset($0) }
        backgrounds += [.auto, .none]
        swatches = backgrounds.map { bg in
            BeautifySwatch(background: bg, auto: { [weak self] in self?.auto ?? BeautifyMath.presets[0] }) { [weak self] in
                guard let self else { return }
                var s = self.style
                s.background = bg
                self.setStyle(s)
            }
        }
        customSwatch = BeautifySwatch(background: .solid(style.custom), auto: { BeautifyMath.presets[0] }) { [weak self] in
            self?.pickCustomColor()
        }
        swatches.append(customSwatch)
        let rows = stride(from: 0, to: swatches.count, by: 6).map { i -> NSStackView in
            let row = NSStackView(views: Array(swatches[i..<min(i + 6, swatches.count)]))
            row.spacing = 8
            return row
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8

        paddingControl.target = self
        paddingControl.action = #selector(controlsChanged)
        cornerControl.target = self
        cornerControl.action = #selector(controlsChanged)
        shadowBox.target = self
        shadowBox.action = #selector(controlsChanged)
        ratioControl.target = self
        ratioControl.action = #selector(controlsChanged)

        func section(_ title: String, _ view: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = Theme.small(.semibold)
            label.textColor = .secondaryLabelColor
            let s = NSStackView(views: [label, view])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 6
            return s
        }
        let hint = NSTextField(labelWithString: "自动 = 跟着截图的主色；无 = 四周透明；最后一个 = 自己挑颜色")
        hint.font = Theme.small()
        hint.textColor = .tertiaryLabelColor
        let controls = NSStackView(views: [section("背景", grid), hint, section("比例", ratioControl), section("留白", paddingControl),
                                           section("圆角", cornerControl), shadowBox])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 14

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let pin = NSButton(title: "钉成贴图", target: self, action: #selector(pinIt))
        let done = NSButton(title: "完成：复制并保存", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        buttons = ["cancel": cancel, "pin": pin, "done": done]
        let buttonRow = NSStackView(views: [cancel, pin, done])
        buttonRow.spacing = 8

        let right = NSStackView(views: [controls, NSView(), buttonRow])
        right.orientation = .vertical
        right.alignment = .leading
        right.distribution = .fill
        let main = NSStackView(views: [preview, right])
        main.orientation = .horizontal
        main.alignment = .top
        main.spacing = 20
        main.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = main
        window.setContentSize(main.fittingSize)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func setStyle(_ s: BeautifyStyle) {
        style = s
        Settings.beautifyStyle = s
        refresh()
    }

    @objc func controlsChanged() {
        var s = style
        s.padding = BeautifyStyle.Level(rawValue: paddingControl.selectedSegment) ?? .medium
        s.corner = BeautifyStyle.Corner(rawValue: cornerControl.selectedSegment) ?? .small
        s.shadow = shadowBox.state == .on
        s.ratio = BeautifyStyle.Ratio(rawValue: ratioControl.selectedSegment) ?? .original
        setStyle(s)
    }

    /// 点"自选"：先换成上次自选的颜色，再打开系统的取色盘接着挑
    func pickCustomColor() {
        applyCustomColor(style.custom)
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(srgbRed: style.custom.r, green: style.custom.g, blue: style.custom.b, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        ownsColorPanel = true
        panel.orderFront(nil)
    }

    @objc func colorPanelChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        applyCustomColor(BeautifyColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)))
    }

    /// 背景换成这个纯色，并记成"上次自选的颜色"
    func applyCustomColor(_ c: BeautifyColor) {
        var s = style
        s.custom = c
        s.background = .solid(c)
        setStyle(s)
    }

    private func refresh() {
        customSwatch.background = .solid(style.custom)
        for swatch in swatches { swatch.isSelectedLook = swatch.background == style.background }
        ratioControl.selectedSegment = style.ratio.rawValue
        paddingControl.selectedSegment = style.padding.rawValue
        cornerControl.selectedSegment = style.corner.rawValue
        shadowBox.state = style.shadow ? .on : .off
        // 预览按预览框的大小画，不按原图大小画，改样式时不卡
        let canvas = BeautifyMath.layout(imageSize: pointSize, style: style).canvas
        let fit = min(Self.previewBox.width / canvas.width, Self.previewBox.height / canvas.height, 1)
        let backing = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        if let image = BeautifyRenderer.render(source, pointSize: pointSize, style: style, scale: fit * backing, autoGradient: auto) {
            preview.image = NSImage(cgImage: image, size: CGSize(width: canvas.width * fit, height: canvas.height * fit))
        }
    }

    /// 原图清晰度的成品
    func result() -> (image: CGImage, pointSize: CGSize)? {
        let scale = CGFloat(source.width) / pointSize.width
        guard let image = BeautifyRenderer.render(source, pointSize: pointSize, style: style, scale: scale, autoGradient: auto)
        else { return nil }
        return (image, BeautifyMath.layout(imageSize: pointSize, style: style).canvas)
    }

    @objc func done() {
        guard let r = result() else { return }
        close()
        onDone?(r.image, r.pointSize)
    }

    @objc func pinIt() {
        guard let r = result() else { return }
        close()
        onPin?(r.image, r.pointSize)
    }

    @objc func cancel() { close() }

    private func close() {
        window.delegate = nil
        window.orderOut(nil)
        releaseColorPanel()
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        releaseColorPanel()
        onClose?()
    }

    /// 关美化窗口时取色盘也收起，不再往这里送颜色
    private func releaseColorPanel() {
        guard ownsColorPanel, NSColorPanel.sharedColorPanelExists else { return }
        ownsColorPanel = false
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
    }
}

/// 背景色块：渐变 / 自动 / 无（棋盘格），选中时外面一圈主题色
@MainActor
final class BeautifySwatch: NSButton {
    /// "自选"色块要跟着上次挑的颜色变，所以能改
    var background: BeautifyStyle.Background { didSet { if background != oldValue { needsDisplay = true } } }
    private let autoGradient: () -> BeautifyGradient
    private let handler: () -> Void
    var isSelectedLook = false { didSet { needsDisplay = true } }

    init(background: BeautifyStyle.Background, auto: @escaping () -> BeautifyGradient, handler: @escaping () -> Void) {
        self.background = background
        autoGradient = auto
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
        toolTip = switch background {
        case .preset(let i): BeautifyMath.presets[i].name
        case .auto: "自动配色（跟着截图的主色）"
        case .none: "不要背景（四周透明）"
        case .solid: "自选颜色（点了打开取色盘）"
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: 4, dy: 4)
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let g = BeautifyRenderer.gradient(for: background, auto: autoGradient()),
           let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [BeautifyRenderer.cgColor(g.from), BeautifyRenderer.cgColor(g.to)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])
        } else {
            // 棋盘格 = 透明
            for y in stride(from: box.minY, to: box.maxY, by: 6) {
                for x in stride(from: box.minX, to: box.maxX, by: 6) {
                    let dark = (Int((x - box.minX) / 6) + Int((y - box.minY) / 6)) % 2 == 0
                    ctx.setFillColor((dark ? NSColor(white: 0.75, alpha: 1) : NSColor.white).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
        ctx.restoreGState()
        if background == .auto, let star = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white]))) {
            star.draw(in: CGRect(x: box.midX - 7, y: box.midY - 7, width: 14, height: 14))
        }
        if case .solid = background, let drop = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [.white]))) {
            drop.draw(in: CGRect(x: box.midX - 7, y: box.midY - 7, width: 14, height: 14))      // 取色笔：一看就知道能自己挑
        }
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        if isSelectedLook {
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setStrokeColor(Theme.accent.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokePath()
        }
    }
}

/// 美化积木：截图工具栏"美化"、贴图右键"美化…"都开这里。完成 = 复制 + 存 PNG（拍板）
@MainActor
final class BeautifyTool: ToolModule {
    /// 钉成贴图：交给贴图积木（AppDelegate 里接上）
    var onPin: ((CGImage, CGSize) -> Void)?
    private(set) var window: BeautifyWindow?

    func activate() {}
    func menuItems() -> [NSMenuItem] { [] }

    /// 截图那边结束时 MacKit 会先把自己藏起来交还焦点，所以等一下再开窗口
    func open(_ image: CGImage, pointSize: CGSize, present: Bool = true) {
        window?.window.orderOut(nil)
        let w = BeautifyWindow(image: image, pointSize: pointSize, style: Settings.beautifyStyle)
        w.onDone = { [weak self] image, size in self?.deliver(image, size) }
        w.onPin = { [weak self] image, size in self?.onPin?(image, size) }
        w.onClose = { [weak self, weak w] in
            if self?.window === w { self?.window = nil }
            if present, NSApp.modalWindow == nil { NSApp.hide(nil) }        // 关掉窗口：焦点还给原来的软件
        }
        window = w
        Log.capture.notice("beautify opened \(image.width)x\(image.height)")
        guard present else { return }
        Task { @MainActor in w.show() }
    }

    private func deliver(_ image: CGImage, _ size: CGSize) {
        guard let out = Self.output(image, pointSize: size, pasteboard: .general, folder: Settings.saveFolder) else {
            Toast.show("美化失败：图片编码出错")
            return
        }
        Toast.show(out.saved ? "✓ 美化好了，已复制并保存　\(image.width)×\(image.height)" : "✓ 美化好了，已复制（保存失败）")
    }

    /// 复制到剪贴板 + 存 PNG（自检用私有剪贴板和临时文件夹）
    static func output(_ image: CGImage, pointSize: CGSize, pasteboard: NSPasteboard, folder: URL) -> (url: URL?, saved: Bool)? {
        guard let png = ImageOutput.pngData(of: image, pointSize: pointSize) else { return nil }
        ImageOutput.copyToClipboard(image, pointSize: pointSize, png: png, to: pasteboard)
        let url = try? ImageOutput.save(png: png, to: folder)
        return (url, url != nil)
    }
}
