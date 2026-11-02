import AppKit

/// 自检：MacKit --selftest
/// 不弹窗、不碰剪贴板、不截真实屏幕，用假图片把"选区 → 裁剪 → 存文件"走一遍
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String) {
        print(ok ? "PASS" : "FAIL", name)
        if !ok { failures += 1 }
    }

    private static func info(_ text: String) { print("INFO", text) }

    static func run(statusItem: NSStatusItem, screenshot: ScreenshotTool, pin: PinTool) {
        check(statusItem.button?.image != nil, "菜单栏图标已创建")
        info("截图快捷键 \(Settings.screenshotHotKey.display) 注册\(screenshot.hotKeyRegistered ? "成功" : "失败")")
        if let rival = Settings.screenshotHotKey.runningRival { info("\(rival) 正开着，也在用这个快捷键") }
        info("贴图快捷键 \(Settings.pinHotKeys.pin.display) / \(Settings.pinHotKeys.toggle.display) 注册\(pin.hotKeysRegistered ? "成功" : "失败")")
        info("屏幕录制权限：\(ScreenPermission.isGranted ? "已开启" : "未开启")（直接从终端运行时，这里查的是终端的权限）")

        if let menu = statusItem.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            check(menu.items.count >= 6, "菜单能生成（\(menu.items.count) 项）")
            info("菜单：" + menu.items.map { $0.isSeparatorItem ? "——" : $0.title }.joined(separator: " | "))
        } else {
            check(false, "菜单存在")
        }

        testOverlay()
        testOutput()
        testPinWindow()
        testPinContent(pin: pin)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 选区覆盖层

    private static func testOverlay() {
        let viewSize = CGSize(width: 1512, height: 982)     // 14 寸 MacBook Pro 的屏幕点数
        let image = makeTestImage(width: 3024, height: 1964)
        let windowRect = CGRect(x: 300, y: 300, width: 400, height: 200)
        let view = SelectionView(frame: CGRect(origin: .zero, size: viewSize), image: image,
                                 windowRects: [windowRect], scale: 2)
        var selected: CGRect?
        view.onSelect = { selected = $0 }

        view.mouseMoved(with: mouse(.mouseMoved, 400, 400))
        check(view.currentSelection == windowRect, "鼠标悬停在窗口上 → 高亮这个窗口")
        view.mouseMoved(with: mouse(.mouseMoved, 1000, 800))
        check(view.currentSelection == CGRect(origin: .zero, size: viewSize), "鼠标悬停在桌面 → 高亮整屏")

        view.mouseDown(with: mouse(.leftMouseDown, 400, 400))
        view.mouseUp(with: mouse(.leftMouseUp, 400, 400))
        check(selected == windowRect, "单击 → 选中窗口")

        // 蓝色方块在图片像素 (200…400, 200…400)，换成视图坐标是 x 100…200、y 782…882
        selected = nil
        view.mouseDown(with: mouse(.leftMouseDown, 100, 882))
        view.mouseDragged(with: mouse(.leftMouseDragged, 150, 830))
        view.mouseDragged(with: mouse(.leftMouseDragged, 200, 782))
        view.mouseUp(with: mouse(.leftMouseUp, 200, 782))
        check(selected == CGRect(x: 100, y: 782, width: 100, height: 100), "拖动框选 → 区域正确")

        if let sel = selected,
           let result = SelectionSession.crop(image: image, viewSize: viewSize, rect: sel, screenOrigin: CGPoint(x: 1512, y: 0)) {
            check(result.image.width == 200 && result.image.height == 200, "裁出 200×200 像素（Retina 2 倍）")
            check(result.pointSize == NSSize(width: 100, height: 100), "记录的显示尺寸是 100×100 点")
            check(result.globalFrame == CGRect(x: 1612, y: 782, width: 100, height: 100), "记下截取区域在屏幕上的原位置（含屏幕偏移）")
            let p = pixel(result.image, x: 100, y: 100)
            check(p.b > 200 && p.r < 60 && p.g < 60, "裁出来的正是蓝色方块")
        } else {
            check(false, "裁剪")
        }

        // 画面方向：图片顶部是红色，覆盖层顶部也应该是红色（不能上下颠倒）
        view.mouseExited(with: mouse(.mouseMoved, 0, 0))
        if let rendered = render(view) {
            let top = pixel(rendered, x: 700, y: 20)
            let bottom = pixel(rendered, x: 700, y: rendered.height - 20)
            check(top.r > top.g + 40, "覆盖层画面方向正确（顶部是红色）")
            check(abs(bottom.r - bottom.g) < 20, "覆盖层底部是灰色")
        } else {
            check(false, "渲染覆盖层")
        }
    }

    // MARK: 存文件

    private static func testOutput() {
        let image = makeTestImage(width: 400, height: 300)
        guard let png = ImageOutput.pngData(of: image, pointSize: NSSize(width: 200, height: 150)) else {
            check(false, "PNG 编码")
            return
        }
        check(png.count > 100, "PNG 编码成功")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let a = try ImageOutput.save(png: png, to: dir)
            let b = try ImageOutput.save(png: png, to: dir)
            check(a != b && FileManager.default.fileExists(atPath: b.path), "同一秒存两张不会互相覆盖")
            info("文件名示例：\(a.lastPathComponent)、\(b.lastPathComponent)")
            let rep = NSBitmapImageRep(data: try Data(contentsOf: a))
            check(rep?.pixelsWide == 400 && rep?.size.width == 200, "存下的图片像素和 Retina 标记都对")
        } catch {
            check(false, "存文件：\(error.localizedDescription)")
        }
    }

    // MARK: 贴图窗口（只造不显示）

    private static func testPinWindow() {
        let image = makeTestImage(width: 400, height: 300)
        let pin = PinWindow(image: image, pointSize: NSSize(width: 200, height: 150),
                            frame: CGRect(x: 100, y: 100, width: 200, height: 150), scale: 1)
        check(pin.level == .floating && pin.collectionBehavior.contains(.canJoinAllSpaces)
              && pin.collectionBehavior.contains(.fullScreenAuxiliary), "贴图浮在最上层，跨所有桌面和全屏应用")
        check(!pin.canHide && !pin.hidesOnDeactivate, "截完图 MacKit 藏起来时，贴图不会跟着消失")

        pin.zoom(to: 2, anchor: CGPoint(x: 200, y: 175))
        check(pin.frame == CGRect(x: 0, y: 25, width: 400, height: 300) && pin.scale == 2, "放大到 200%，鼠标指的点不动")
        pin.resetSize()
        check(pin.frame.size == CGSize(width: 200, height: 150) && pin.scale == 1, "恢复原始大小")

        let before = pin.scale
        if let view = pin.contentView, let wheel = scrollEvent(lines: 1, option: false) {
            view.scrollWheel(with: wheel)
            check(abs(pin.scale - before) > 0.05 && abs(pin.alphaValue - 1) < 0.001, "滚轮一格 → 缩放变了、透明度没变")
        } else { check(false, "造滚轮事件") }
        let scaleNow = pin.scale
        pin.setOpacity(0.5)          // 从 50% 开始，往哪边滚都看得出变化
        if let view = pin.contentView, let wheel = scrollEvent(lines: 1, option: true) {
            view.scrollWheel(with: wheel)
            check(pin.scale == scaleNow && abs(pin.alphaValue - 0.5) > 0.01, "⌥ + 滚轮 → 透明度变了、缩放没变")
        } else { check(false, "造 ⌥ 滚轮事件") }

        pin.setOpacity(0.01)
        check(abs(pin.alphaValue - 0.1) < 0.001, "透明度最低 10%")
        pin.setOpacity(1)
        pin.setClickThrough(true)
        check(pin.ignoresMouseEvents && pin.alphaValue <= 0.7 + 0.001, "鼠标穿透：点击穿过去，图变成半透明")
        pin.setClickThrough(false)
        check(!pin.ignoresMouseEvents && pin.alphaValue == 1, "取消穿透，恢复不透明")

        let menu = pin.makeContextMenu()
        let titles = menu.items.map(\.title)
        check(["复制", "另存为…", "关闭（Esc）", "关闭全部贴图"].allSatisfy(titles.contains)
              && titles.contains { $0.hasPrefix("鼠标穿透") } && titles.contains { $0.hasPrefix("透明度") },
              "右键菜单齐全（\(menu.items.filter { !$0.isSeparatorItem }.count) 项）")

        var closed = false
        pin.onClosed = { _ in closed = true }
        pin.closePin()
        check(closed && !pin.isVisible, "关闭贴图")
    }

    // MARK: 贴什么、贴在哪（用私有剪贴板，不碰你真正的剪贴板）

    private static func testPinContent(pin tool: PinTool) {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally(); CaptureHistory.last = nil }
        let image = makeTestImage(width: 400, height: 300)
        guard let png = ImageOutput.pngData(of: image, pointSize: NSSize(width: 200, height: 150)) else {
            check(false, "PNG 编码"); return
        }

        // 1. 刚截的图 → 贴回原位置
        pb.clearContents()
        pb.setData(png, forType: .png)
        let origin = CGRect(x: 321, y: 456, width: 200, height: 150)
        CaptureHistory.record(image: image, pointSize: NSSize(width: 200, height: 150), globalFrame: origin, pasteboard: pb)
        if case .original(let record)? = PinContentReader.read(pb),
           let pin = tool.makePin(for: .original(record), mouse: .zero) {
            check(pin.frame == origin && pin.scale == 1, "剪贴板没变过 → 截图贴回原位置、原大小")
        } else { check(false, "刚截的图贴回原位置") }

        // 2. 剪贴板被别的软件改过（同一张图也算新的）→ 按普通图片贴在鼠标旁边
        pb.clearContents()
        pb.setData(png, forType: .png)
        if case .image(let img, let size)? = PinContentReader.read(pb) {
            check(img.width == 400 && size == NSSize(width: 200, height: 150), "别处复制的图片：像素和 Retina 尺寸都对")
            let mouse = NSScreen.main.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? CGPoint(x: 500, y: 500)
            if let pin = tool.makePin(for: .image(img, pointSize: size), mouse: mouse) {
                check(abs(pin.frame.midX - mouse.x) < 1 && abs(pin.frame.midY - mouse.y) < 1, "别处复制的图片贴在鼠标位置")
            } else { check(false, "图片贴图") }
        } else { check(false, "读剪贴板里的图片") }

        // 3. 文字 → 文字卡片
        pb.clearContents()
        pb.setString("你好 MacKit\n第二行文字", forType: .string)
        if case .text(let text)? = PinContentReader.read(pb) {
            check(text.hasPrefix("你好"), "读出剪贴板里的文字")
            if let card = TextCard.render(text, scale: 2) {
                check(card.pointSize.width > 60 && card.pointSize.height > 40 && card.image.width == Int(card.pointSize.width * 2),
                      "文字画成卡片（\(Int(card.pointSize.width))×\(Int(card.pointSize.height)) 点）")
                let topLeft = pixel(card.image, x: 3, y: 3)
                let bottomRight = pixel(card.image, x: card.image.width - 3, y: card.image.height - 3)
                check([topLeft, bottomRight].allSatisfy { $0.r > 240 && $0.g > 240 && $0.b > 240 },
                      "文字卡片整张都是白底（左上 \(topLeft.r)，右下 \(bottomRight.r)）")
                var dark = 0
                for y in stride(from: 0, to: card.image.height, by: 4) {
                    for x in stride(from: 0, to: card.image.width, by: 4) where pixel(card.image, x: x, y: y).r < 100 { dark += 1 }
                }
                check(dark > 20, "卡片上真的画出了文字")
            } else { check(false, "画文字卡片") }
        } else { check(false, "读剪贴板里的文字") }

        // 4. 访达里复制的图片文件
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("图.png")
            try png.write(to: file)
            pb.clearContents()
            pb.writeObjects([file as NSURL])
            if case .image(let img, _)? = PinContentReader.read(pb) {
                check(img.width == 400, "访达里复制的图片文件也能贴")
            } else { check(false, "读图片文件") }
        } catch { check(false, "准备图片文件：\(error.localizedDescription)") }

        // 5. 空剪贴板
        pb.clearContents()
        check(PinContentReader.read(pb) == nil, "剪贴板是空的 → 不贴，给提示")
    }

    // MARK: 工具

    private static func scrollEvent(lines: Int32, option: Bool) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
        if option { cg.flags = .maskAlternate }
        return NSEvent(cgEvent: cg)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// 灰底；顶部 100 行红色；像素 (200…400, 200…400) 一个蓝色方块（像素坐标左上为原点）
    private static func makeTestImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - 100, width: width, height: 100))       // CGContext 原点在左下
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 200, y: height - 400, width: 200, height: 200))
        return ctx.makeImage()!
    }

    private static func render(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// 读一个像素的颜色，y 从上往下数
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
