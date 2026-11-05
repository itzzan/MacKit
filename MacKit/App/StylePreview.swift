import AppKit

/// 样张：MacKit --style-preview <输出.png> <标题> [<左边那一栏.png>]
/// 把各个浮动条、按钮、提示条画进一张图（不弹任何窗口）。给了左边那一栏，就并排拼成"现在 / 改后"对比图。
/// 注意：毛玻璃在样张里画成实色（真正显示时是半透明的）
@MainActor
enum StylePreview {
    struct Sample {
        let title: String
        let view: NSView
    }

    /// MacKit --welcome-preview <输出.png> [dark]：把欢迎窗口画成图（不弹窗口、不改设置）
    static func runWelcome(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--welcome-preview"), arguments.indices.contains(i + 1) else { exit(2) }
        let dark = arguments.contains("dark")
        let w = WelcomeWindow()
        guard let content = w.window.contentView else { exit(1) }
        content.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        ctx.setFillColor((dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage(), write(out, to: arguments[i + 1]) else { exit(1) }
        print("欢迎窗口：\(arguments[i + 1])　\(out.width)×\(out.height)")
        exit(0)
    }

    /// 设置窗口五页各画一张图（不弹窗口、不改设置）：--settings-preview 输出前缀 [dark] → 前缀-通用.png …
    static func runSettings(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--settings-preview"), arguments.indices.contains(i + 1) else { exit(2) }
        let dark = arguments.contains("dark")
        var hooks = SettingsHooks()
        hooks.dryRun = true
        let settings = SettingsWindow(hooks: hooks)
        for pane in SettingsWindow.Pane.allCases {
            guard let view = settings.panes[pane]?.view else { exit(1) }
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
            ctx.setFillColor((dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let path = "\(arguments[i + 1])-\(pane.title).png"
            guard let out = ctx.makeImage(), write(out, to: path) else { exit(1) }
            print("设置 \(pane.title)：\(path)　\(out.width)×\(out.height)")
        }
        exit(0)
    }

    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--style-preview"), arguments.indices.contains(i + 2) else { exit(2) }
        let out = arguments[i + 1], label = arguments[i + 2]
        let third = arguments.indices.contains(i + 3) ? arguments[i + 3] : nil
        let readme = third == "readme"                   // 给 README 用的界面一览：不画"按钮的几种样子"
        let left = readme ? nil : third
        Theme.solidBars = true                   // 毛玻璃画不出来，样张里用实色
        let note = readme ? "示意图：屏幕上这些条是半透明的毛玻璃"
            : left == nil ? "毛玻璃在图里画不出来：这一栏的灰底在屏幕上其实是半透明的深色"
                          : "用接近屏幕上真实效果的深色实底画（屏幕上是半透明毛玻璃）"
        let list = samples().filter { !(readme && $0.title.hasPrefix("按钮")) }
        let column = renderColumn(label: label, samples: list, note: note)
        var image = column
        if let left, let leftImage = load(left), let column {
            image = sideBySide(leftImage, column, leftNote: "毛玻璃在图里画不出来：这一栏的灰底在屏幕上其实是半透明的深色")
        }
        guard let image, write(image, to: out) else { print("样张失败"); exit(1) }
        print("样张：\(out)　\(image.width)×\(image.height)")
        exit(0)
    }

    /// 要画的东西（都用真正的界面代码造出来，只是不显示）
    static func samples() -> [Sample] {
        var list: [Sample] = []

        let toolbar = AnnotationToolbar(mode: .screenshot)
        toolbar.update(tool: .rect, color: .red, size: .medium, canUndo: true, canRedo: false)
        list.append(Sample(title: "截图工具栏（选了矩形，下面一排是颜色和粗细）", view: toolbar))

        let pinBar = AnnotationToolbar(mode: .pin, standalone: true)
        pinBar.update(tool: .arrow, color: .red, size: .medium, canUndo: true, canRedo: false)
        list.append(Sample(title: "贴图上标注的工具栏", view: pinBar))

        list.append(Sample(title: "按钮：普通 / 鼠标放上去 / 按下 / 选中 / 主按钮 / 停止", view: buttonStrip()))

        let control = RecordingControlBar(systemAudio: true, microphone: false)
        if let v = control.panel.contentView { list.append(Sample(title: "录屏前的控制条", view: v)) }

        let recording = RecordingHUD(systemAudio: true, microphone: true)
        recording.update("01:23")
        if let v = recording.panel.contentView { list.append(Sample(title: "录制小条：正在录", view: v)) }
        let paused = RecordingHUD(systemAudio: true, microphone: false)
        paused.setMode(.paused)
        paused.update("01:23")
        if let v = paused.panel.contentView { list.append(Sample(title: "录制小条：暂停了", view: v)) }

        let longShot = LongShotControlBar()
        longShot.setStatus(LongShotGeometry.progressText(totalHeight: 6200, screens: 3.2))
        if let v = longShot.panel.contentView { list.append(Sample(title: "长截图控制条", view: v)) }

        if let v = Toast.makePanel("✓ 已复制到剪贴板，已保存　1200×800").contentView {
            list.append(Sample(title: "提示条：成功", view: v))
        }
        if let v = Toast.makePanel("截图失败：图片编码出错").contentView { list.append(Sample(title: "提示条：失败", view: v)) }
        if let v = Toast.makeActionsPanel("✓ 已录好：MacKit_录屏_2026-11-04.mp4",
                                          actions: [("预览剪辑", {}), ("存成 GIF", {}), ("在访达中显示", {})]).contentView {
            list.append(Sample(title: "带按钮的提示条", view: v))
        }

        let keys = KeyCastWindow()
        keys.show("⌘C", present: false)
        keys.show("⌘V", present: false)
        if let v = keys.panel.contentView { list.append(Sample(title: "录屏时的按键牌子", view: v)) }

        let countdown = CountdownWindow(center: .zero, hint: "Esc 取消")
        countdown.label.stringValue = "3"
        if let v = countdown.panel.contentView { list.append(Sample(title: "倒数（录屏、延时截图）", view: v)) }

        let labelHost = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        labelHost.wantsLayer = true
        let sizeLabel = LabelLayer()
        let size = sizeLabel.set("1200 × 800", scale: 2)
        sizeLabel.frame = CGRect(origin: .zero, size: size)
        labelHost.setFrameSize(size)
        labelHost.layer?.addSublayer(sizeLabel)
        list.append(Sample(title: "截图时的尺寸标签", view: labelHost))
        return list
    }

    /// 一排按钮的几种样子（改之前没有"鼠标放上去""按下"的变化，前三个一样）
    static func buttonStrip() -> NSView {
        let plain = ToolbarButton(symbol: "rectangle", tip: "") {}
        let hover = ToolbarButton(symbol: "circle", tip: "") {}
        hover.isHoveredLook = true
        let pressed = ToolbarButton(symbol: "arrow.up.right", tip: "") {}
        pressed.isPressedLook = true
        let selected = ToolbarButton(symbol: "pencil", tip: "") {}
        selected.isSelectedLook = true
        let done = ToolbarButton(symbol: "checkmark", tip: "", style: .primary) {}
        let stop = ToolbarButton(symbol: "stop.fill", title: "停止", tip: "", style: .danger) {}
        let row = Theme.row([plain, hover, pressed, selected, done, stop], spacing: 8)
        let bg = Theme.bar(containing: row)
        bg.setFrameSize(row.fittingSize)
        return bg
    }

    // MARK: 画

    static let scale: CGFloat = 2
    static let pad: CGFloat = 28

    /// 一个界面 → 图片（放进一个不显示的窗口里排好版再画）
    static func snapshot(_ view: NSView) -> CGImage? {
        if view.frame.size == .zero { view.setFrameSize(view.fittingSize) }
        let host = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: view.frame.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.appearance = NSAppearance(named: .darkAqua)
        if view.window == nil { host.contentView = view }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func renderColumn(label: String, samples: [Sample], note: String? = nil) -> CGImage? {
        let shots = samples.compactMap { s in snapshot(s.view).map { (s.title, $0, s.view.bounds.size) } }
        let width = max(760, (shots.map { $0.2.width }.max() ?? 0) + pad * 2)
        let height = 70 + shots.reduce(0) { $0 + 26 + $1.2.height + 26 } + pad
        let pxW = Int(width * scale), pxH = Int(height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // 背景：浅色网页一样的底，再铺几块颜色，模拟浮动条盖在截图上
        ctx.setFillColor(NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let tints: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen]
        for k in 0..<Int(height / 160) {
            ctx.setFillColor(tints[k % tints.count].withAlphaComponent(0.10).cgColor)
            ctx.fill(CGRect(x: CGFloat(k % 2) * width / 2, y: CGFloat(k) * 160, width: width / 2, height: 160))
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        var y = height - 46
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black]
        (label as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: titleAttrs)
        if let note {
            let titleWidth = (label as NSString).size(withAttributes: titleAttrs).width
            (note as NSString).draw(at: CGPoint(x: pad + max(80, titleWidth + 24), y: y + 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
        }
        y -= 24
        for (title, image, size) in shots {
            y -= 20
            (title as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.darkGray])
            y -= 6 + size.height
            ctx.draw(image, in: CGRect(x: pad, y: y, width: size.width, height: size.height))
            y -= 26
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func sideBySide(_ a: CGImage, _ b: CGImage, leftNote: String) -> CGImage? {
        let w = a.width + b.width + 4, h = max(a.height, b.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: h - a.height, width: a.width, height: a.height))
        ctx.setFillColor(NSColor.gray.cgColor)
        ctx.fill(CGRect(x: a.width, y: 0, width: 4, height: h))
        ctx.draw(b, in: CGRect(x: a.width + 4, y: h - b.height, width: b.width, height: b.height))
        // 左边那一栏是改之前画的，没有说明，这里补上
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        (leftNote as NSString).draw(at: CGPoint(x: pad + 80, y: CGFloat(h) / scale - 41), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func load(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func write(_ image: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
