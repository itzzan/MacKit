import AppKit
import AVFoundation
import ImageIO
import CoreMedia

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

    static func run(statusItem: NSStatusItem, screenshot: ScreenshotTool, pin: PinTool, recorder: RecorderTool,
                    emergencyQuit: Bool) {
        check(statusItem.button?.image != nil, "菜单栏图标已创建")
        check(emergencyQuit, "紧急退出快捷键 \(EmergencyHotKey.quit.display) 已注册")
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
        testAnnotationExport()
        testEditingFlow()
        testTextEditing()
        testPinAnnotation()
        testClipboard()
        testRecorder(recorder)
        testRecordingExtras(recorder)

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
        if let view = pin.pinView, let wheel = scrollEvent(lines: 1, option: false) {
            view.scrollWheel(with: wheel)
            check(abs(pin.scale - before) > 0.05 && abs(pin.alphaValue - 1) < 0.001, "滚轮一格 → 缩放变了、透明度没变")
        } else { check(false, "造滚轮事件") }
        let scaleNow = pin.scale
        pin.setOpacity(0.5)          // 从 50% 开始，往哪边滚都看得出变化
        if let view = pin.pinView, let wheel = scrollEvent(lines: 1, option: true) {
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

    // MARK: 标注导出（每种工具画在假图片上，检查像素）

    private static func testAnnotationExport() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let mosaic = MosaicSource(image: image, viewSize: viewSize)
        let sel = CGRect(x: 50, y: 550, width: 500, height: 400)
        // 视图坐标(点) → 导出图里的像素（左上原点）
        func px(_ x: CGFloat, _ y: CGFloat) -> (Int, Int) { (Int((x - sel.minX) * 2), Int((sel.maxY - y) * 2)) }

        let items: [Annotation] = [
            Annotation(tool: .rect, color: .red, size: .medium, points: [CGPoint(x: 300, y: 600), CGPoint(x: 400, y: 700)]),
            Annotation(tool: .mosaic, color: .red, size: .thick, points: [CGPoint(x: 150, y: 800), CGPoint(x: 250, y: 860)]),
            Annotation(tool: .number, color: .red, size: .medium, points: [CGPoint(x: 450, y: 900)], number: 1),
            Annotation(tool: .arrow, color: .red, size: .medium, points: [CGPoint(x: 100, y: 600), CGPoint(x: 250, y: 650)]),
            Annotation(tool: .highlighter, color: .yellow, size: .medium, points: [CGPoint(x: 300, y: 900), CGPoint(x: 400, y: 900)]),
            Annotation(tool: .pen, color: .blue, size: .medium, points: [CGPoint(x: 60, y: 560), CGPoint(x: 120, y: 580)]),
            Annotation(tool: .text, color: .red, size: .thick, points: [CGPoint(x: 60, y: 760)], text: "Hi 你好"),
        ]
        guard let result = AnnotationExporter.export(image: image, viewSize: viewSize, selection: sel,
                                                     screenOrigin: .zero, annotations: items, mosaic: mosaic) else {
            check(false, "导出带标注的图"); return
        }
        let out = result.image
        check(out.width == 1000 && out.height == 800 && result.pointSize == NSSize(width: 500, height: 400),
              "导出 1000×800 像素（Retina 2 倍），标注也是 2 倍")

        let isRed = { (p: (r: Int, g: Int, b: Int)) in p.r > 200 && p.g < 110 && p.b < 110 }
        var (x, y) = px(300, 650)
        check(isRed(pixel(out, x: x, y: y)), "矩形的边是红色")
        (x, y) = px(350, 650)
        let inside = pixel(out, x: x, y: y)
        check(abs(inside.r - inside.g) < 20, "矩形中间是空的（只描边）")
        (x, y) = px(175, 625)
        check(isRed(pixel(out, x: x, y: y)), "箭头杆是红色")
        (x, y) = px(442, 900)
        check(isRed(pixel(out, x: x, y: y)), "序号是红色实心圆")
        (x, y) = px(90, 570)
        let pen = pixel(out, x: x, y: y)
        check(pen.b > 200 && pen.r < 60, "画笔是蓝色")
        (x, y) = px(350, 900)
        let hl = pixel(out, x: x, y: y)
        check(hl.r > 160 && hl.r < 235 && hl.b < 100, "荧光笔是半透明黄色（盖在灰底上）")

        // 马赛克：蓝块右边缘在 x = 200 点，16 点一格 → 跨边缘那格是蓝灰混色，同一格里颜色一样
        (x, y) = px(200, 830)
        let mixed = pixel(out, x: x, y: y)
        check(mixed.b > mixed.g + 40 && mixed.b < 245 && mixed.r > 15, "马赛克把蓝块边缘糊成一格一格")
        let (ax, ay) = px(195, 830), (bx, by) = px(205, 830)
        let a = pixel(out, x: ax, y: ay), b = pixel(out, x: bx, y: by)
        check(abs(a.r - b.r) <= 2 && abs(a.g - b.g) <= 2 && abs(a.b - b.b) <= 2, "马赛克同一格里颜色一样")
        (x, y) = px(235, 830)
        let grayBlock = pixel(out, x: x, y: y)
        let original = pixel(image, x: 470, y: 304)       // 同一位置在原图里的颜色（屏幕像素）
        check(abs(grayBlock.r - original.r) <= 2 && abs(grayBlock.b - original.b) <= 2,
              "马赛克只糊画面，不会把别处染色")

        let textRect = AnnotationText.rect(for: items[6])
        var redHits = 0
        for ty in stride(from: textRect.minY, to: textRect.maxY, by: 1) {
            for tx in stride(from: textRect.minX, to: textRect.maxX, by: 1) {
                let (qx, qy) = px(tx, ty)
                if isRed(pixel(out, x: qx, y: qy)) { redHits += 1 }
            }
        }
        check(redHits > 20, "文字画在了它的位置上")
    }

    // MARK: 编辑流程（不显示窗口，直接把鼠标键盘事件喂给选区视图）

    private static func testEditingFlow() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: image, viewSize: viewSize))
        defer { editor.tearDown() }
        var done = 0, cancelled = 0
        view.onDone = { done += 1 }
        view.onCancel = { cancelled += 1 }

        let start = CGRect(x: 200, y: 300, width: 400, height: 300)
        view.beginEditing(editor, selection: start)
        check(view.mode == .editing && editor.canAdjustSelection, "松手后进入编辑，框还能调")
        let bar = editor.toolbar.frame
        check(editor.toolbar.superview === container && bar.maxY <= start.minY && bar.maxX <= start.maxX + 0.5
              && bar.width > 300 && bar.height > 30,
              "工具栏出现在框的下方、右对齐（\(Int(bar.width))×\(Int(bar.height)) 点）")
        check(!editor.toolbar.isShowingProperties, "还没选工具时，不显示颜色和粗细")

        view.mouseDown(with: mouse(.leftMouseDown, 600, 300))
        view.mouseDragged(with: mouse(.leftMouseDragged, 700, 250))
        view.mouseUp(with: mouse(.leftMouseUp, 700, 250))
        let resized = CGRect(x: 200, y: 250, width: 500, height: 350)
        check(view.currentSelection == resized && editor.selection == resized, "拖右下角小方块改大小")

        view.mouseDown(with: mouse(.leftMouseDown, 400, 400))
        view.mouseDragged(with: mouse(.leftMouseDragged, 410, 390))
        view.mouseUp(with: mouse(.leftMouseUp, 410, 390))
        check(view.currentSelection == resized.offsetBy(dx: 10, dy: -10), "拖框里面挪位置")

        view.keyDown(with: key("", code: 124))
        check(view.currentSelection?.minX == 211, "方向键 → 挪 1 个点")
        let fixed = view.currentSelection ?? .zero

        view.keyDown(with: key("r", code: 15))
        check(editor.tool == .rect && editor.toolbar.isShowingProperties, "按 R 选矩形，出现颜色和粗细")
        view.mouseDown(with: mouse(.leftMouseDown, 300, 350))
        view.mouseDragged(with: mouse(.leftMouseDragged, 350, 400))
        view.mouseUp(with: mouse(.leftMouseUp, 400, 450))
        check(editor.document.items.count == 1 && editor.document.items[0].box == CGRect(x: 300, y: 350, width: 100, height: 100),
              "画了一个矩形")
        check(!editor.canAdjustSelection, "画了第一笔，框就固定了")

        view.keyDown(with: key("r", code: 15))
        check(editor.tool == nil, "再按一次 R 放下工具")
        view.mouseDown(with: mouse(.leftMouseDown, fixed.maxX, fixed.minY))
        view.mouseDragged(with: mouse(.leftMouseDragged, fixed.maxX + 100, fixed.minY - 50))
        view.mouseUp(with: mouse(.leftMouseUp, fixed.maxX + 100, fixed.minY - 50))
        check(view.currentSelection == fixed, "框固定后拖小方块也不会变")

        _ = view.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(editor.document.items.isEmpty, "⌘Z 撤销")
        _ = view.performKeyEquivalent(with: key("z", code: 6, mods: [.command, .shift]))
        check(editor.document.items.count == 1, "⇧⌘Z 重做")

        view.keyDown(with: key("n", code: 45))
        view.mouseDown(with: mouse(.leftMouseDown, 500, 500)); view.mouseUp(with: mouse(.leftMouseUp, 500, 500))
        view.mouseDown(with: mouse(.leftMouseDown, 550, 500)); view.mouseUp(with: mouse(.leftMouseUp, 550, 500))
        check(editor.document.items.filter { $0.tool == .number }.map(\.number) == [1, 2], "序号点两下 → 1、2")

        view.keyDown(with: key("t", code: 17))
        view.mouseDown(with: mouse(.leftMouseDown, 250, 500)); view.mouseUp(with: mouse(.leftMouseUp, 250, 500))
        check(editor.isEditingText, "文字工具点一下出现输入框")
        editor.textView?.insertText("你好 MacKit", replacementRange: NSRange(location: NSNotFound, length: 0))
        if let tv = editor.textView { _ = editor.textView(tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))) }
        check(!editor.isEditingText && editor.document.items.last?.text == "你好 MacKit", "打中文，按 Esc 结束打字，字留下")
        view.mouseDown(with: mouse(.leftMouseDown, 260, 420)); view.mouseUp(with: mouse(.leftMouseUp, 260, 420))
        view.mouseDown(with: mouse(.leftMouseDown, 300, 400))   // 没打字就点别处
        check(editor.document.items.filter { $0.tool == .text }.count == 1, "空的输入框不会留下")

        let count = editor.document.items.count
        for tool in [AnnotationTool.ellipse, .arrow, .pen, .highlighter, .mosaic] {
            editor.selectTool(tool)
            view.mouseDown(with: mouse(.leftMouseDown, 320, 320))
            view.mouseDragged(with: mouse(.leftMouseDragged, 360, 340))
            view.mouseUp(with: mouse(.leftMouseUp, 400, 360))
        }
        check(editor.document.items.count == count + 5, "椭圆、箭头、画笔、荧光笔、马赛克各画一下")
        check(Set(editor.document.items.map(\.tool)) == Set(AnnotationTool.allCases), "八种工具都画上了")

        editor.selectTool(nil)
        view.keyDown(with: key("\r", code: 36))
        check(done == 1, "回车 = 完成")
        view.mouseDown(with: mouse(.leftMouseDown, 400, 400, clicks: 2))
        check(done == 2, "没选工具时在框里双击 = 完成")
        view.keyDown(with: key("\u{1b}", code: 53))
        check(cancelled == 1, "Esc = 取消")

        if let rect = view.currentSelection,
           let out = AnnotationExporter.export(image: image, viewSize: viewSize, selection: rect, screenOrigin: .zero,
                                               annotations: editor.document.items,
                                               mosaic: MosaicSource(image: image, viewSize: viewSize)) {
            check(out.image.width == Int(rect.width * 2), "编辑完导出，尺寸和框一致")
        } else { check(false, "编辑完导出") }
    }

    // MARK: 文字工具：拼音看得见、写好的字能再改（2026-11-04 用户验收时提的两个问题）

    private static func testTextEditing() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        // 放进一个不显示的窗口：输入框要在窗口里，系统才把它当成"正在拼写"
        let window = OverlayWindow(frame: CGRect(origin: CGPoint(x: -20000, y: -20000), size: viewSize))
        window.contentView = container
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: image, viewSize: viewSize))
        defer { editor.tearDown(); window.contentView = nil }
        var done = 0
        view.onDone = { done += 1 }
        view.beginEditing(editor, selection: CGRect(x: 100, y: 100, width: 800, height: 600))
        let noRange = NSRange(location: NSNotFound, length: 0)

        editor.selectTool(.text)
        view.mouseDown(with: mouse(.leftMouseDown, 200, 500)); view.mouseUp(with: mouse(.leftMouseUp, 200, 500))
        guard let tv = editor.textView else { check(false, "文字工具出现输入框"); return }

        // 1. 拼音拼写中：输入框要跟着变宽
        tv.setMarkedText("nihaoshijie", selectedRange: NSRange(location: 11, length: 0), replacementRange: noRange)
        // 注意：不能碰 tv.layoutManager，一碰输入框就退回旧排版方式，正在拼写的拼音会被直接定下来
        let used = ceil(tv.attributedString().boundingRect(with: CGSize(width: 4000, height: 4000),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
        check(tv.hasMarkedText() && tv.markedRange().length == 11 && tv.frame.width >= used && used > 50,
              "拼音拼写中，输入框跟着变宽（拼音 \(Int(used)) 点，输入框 \(Int(tv.frame.width)) 点）")
        check(tv.drawsBackground && (tv.backgroundColor.alphaComponent > 0.3), "编辑中的输入框有半透明衬底，白底上也看得清")
        if let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) {
            tv.cacheDisplay(in: tv.bounds, to: rep)
            var ink = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       c.alphaComponent > 0.5, c.redComponent + c.greenComponent + c.blueComponent < 1.8 { ink += 1 }
                }
            }
            check(ink > 40, "拼音真的画出来了（\(ink) 个深色像素）")
        }
        check(tv.hasMarkedText(), "量完宽度、截完画面，拼音还在拼写中（没被提前定下来）")
        tv.insertText("你好世界", replacementRange: tv.markedRange())
        check(!tv.hasMarkedText() && tv.string == "你好世界", "选字后拼音换成汉字")
        editor.commitText()
        check(editor.document.items.count == 1 && editor.document.items[0].text == "你好世界", "打完的字落下")

        // 2. 用文字工具点已有的字 → 接着改，改完替换原来那条
        let textRect = AnnotationText.rect(for: editor.document.items[0])
        view.mouseDown(with: mouse(.leftMouseDown, textRect.midX, textRect.midY))
        view.mouseUp(with: mouse(.leftMouseUp, textRect.midX, textRect.midY))
        check(editor.isEditingText && editor.textView?.string == "你好世界" && editor.canvas.annotations.isEmpty,
              "文字工具点已有的字 → 原文进了输入框，画面上先不画原来那条")
        editor.textView?.insertText("！", replacementRange: noRange)
        editor.commitText()
        check(editor.document.items.count == 1 && editor.document.items[0].text == "你好世界！", "改完替换原来那条，不会多出一条")

        _ = view.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(editor.document.items.first?.text == "你好世界", "⌘Z 撤销这次修改")
        _ = view.performKeyEquivalent(with: key("z", code: 6, mods: [.command, .shift]))
        check(editor.document.items.first?.text == "你好世界！", "⇧⌘Z 再改回来")

        // 3. 没选工具时双击字 → 接着改（不是"完成"）
        editor.selectTool(nil)
        view.mouseDown(with: mouse(.leftMouseDown, textRect.midX, textRect.midY, clicks: 2))
        check(editor.isEditingText && done == 0, "没选工具时双击字 → 接着改，不会直接完成")

        // 4. 把字删光 → 这条文字被删掉，也能撤销回来
        if let tv = editor.textView {
            tv.selectAll(nil)
            tv.insertText("", replacementRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }
        editor.commitText()
        check(editor.document.items.isEmpty, "字删光 → 这条文字没了")
        _ = view.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(editor.document.items.first?.text == "你好世界！", "删掉的字也能 ⌘Z 撤销回来")

        // 5. 改字时换颜色、换粗细，改完生效
        editor.selectTool(.text)
        view.mouseDown(with: mouse(.leftMouseDown, textRect.midX, textRect.midY))
        editor.setColor(.blue)
        editor.setSize(.thick)
        editor.commitText()
        check(editor.document.items.first?.color == .blue && editor.document.items.first?.size == .thick,
              "改字时换颜色和粗细，改完生效")
    }

    // MARK: 贴图上的标注（台阶 3 第二批）

    private static func testPinAnnotation() {
        let image = makeTestImage(width: 400, height: 300)
        let pin = PinWindow(image: image, pointSize: NSSize(width: 200, height: 150),
                            frame: CGRect(x: 100, y: 100, width: 200, height: 150), scale: 1)
        var closed = false
        pin.onClosed = { _ in closed = true }
        pin.zoom(to: 2, anchor: CGPoint(x: 100, y: 100))
        check(pin.makeContextMenu().items.first?.title == "标注（空格）", "贴图右键菜单第一项是「标注」")
        let isRed = { (p: (r: Int, g: Int, b: Int)) in p.r > 200 && p.g < 110 && p.b < 110 }

        // 第一次标注：在放大 2 倍的贴图上画框，按回车
        pin.beginAnnotating(present: false)
        guard let first = pin.annotationSession else { check(false, "进入标注"); return }
        first.editor.setColor(.red)          // 不依赖你上次选的颜色
        check(pin.isAnnotating && first.editor.toolbar.mode == .pin && !first.editor.toolbar.hasPinAndSave,
              "进入标注；贴图用的工具栏没有 📌 和 💾")
        first.input.keyDown(with: key("r", code: 15))
        first.input.mouseDown(with: mouse(.leftMouseDown, 100, 100))
        first.input.mouseDragged(with: mouse(.leftMouseDragged, 150, 150))
        first.input.mouseUp(with: mouse(.leftMouseUp, 200, 200))
        check(first.editor.document.items.first?.box == CGRect(x: 50, y: 50, width: 50, height: 50),
              "放大 2 倍的贴图上画框，位置换算回原图")
        first.input.scrollWheel(with: scrollEvent(lines: 1, option: false)!)
        check(pin.scale == 2, "标注时滚轮不会缩放贴图")
        _ = pin.performKeyEquivalent(with: key("w", code: 13, mods: .command))
        check(!closed && pin.isAnnotating, "标注时 ⌘W 不会把贴图关掉")
        first.input.keyDown(with: key("\r", code: 36))
        check(!pin.isAnnotating && pin.document.items.count == 1, "回车完成，标注留在贴图上")
        check(pin.image !== pin.originalImage && isRed(pixel(pin.image, x: 100, y: 150)),
              "贴图合成了标注（复制、另存拿到的是带标注的图）")

        // 第二次：之前画的还在；画个椭圆后按 Esc → 只放弃这一次
        pin.beginAnnotating(present: false)
        guard let second = pin.annotationSession else { check(false, "再次进入标注"); return }
        second.editor.setColor(.red)          // 不依赖你上次选的颜色
        check(second.editor.document.items.count == 1, "再进标注，之前画的都还在")
        second.input.keyDown(with: key("e", code: 14))
        second.input.mouseDown(with: mouse(.leftMouseDown, 250, 50))
        second.input.mouseUp(with: mouse(.leftMouseUp, 350, 150))
        check(second.editor.document.items.count == 2, "又画了一个椭圆")
        second.input.keyDown(with: key("\u{1b}", code: 53))
        check(!pin.isAnnotating && pin.document.items.count == 1 && pin.document.items[0].tool == .rect,
              "Esc：这次画的椭圆没了，之前的框还在")

        // 第三次：⌘Z 能撤销之前画的
        pin.beginAnnotating(present: false)
        guard let third = pin.annotationSession else { check(false, "第三次进入标注"); return }
        third.editor.setColor(.red)          // 不依赖你上次选的颜色
        check(third.editor.document.canUndo, "之前画的也能撤销")
        _ = third.input.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(third.editor.document.items.isEmpty, "⌘Z 撤销了上次画的框")
        third.input.keyDown(with: key("\r", code: 36))
        check(pin.document.items.isEmpty && pin.image === pin.originalImage, "撤销光了再完成，贴图恢复成原图")

        // 第四次：在贴图上打中文；恢复原始大小后标注还在
        pin.beginAnnotating(present: false)
        guard let fourth = pin.annotationSession else { check(false, "第四次进入标注"); return }
        fourth.editor.setColor(.red)          // 不依赖你上次选的颜色
        fourth.input.keyDown(with: key("t", code: 17))
        fourth.input.mouseDown(with: mouse(.leftMouseDown, 40, 160))     // 避开假图片顶部的红带
        fourth.editor.textView?.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        fourth.editor.commitText()
        fourth.input.keyDown(with: key("\r", code: 36))
        let text = pin.document.items.first
        check(text?.tool == .text && text?.text == "你好" && text?.points.first == CGPoint(x: 20, y: 80),
              "贴图上打中文，位置换算回原图")
        pin.resetSize()
        check(pin.scale == 1 && pin.document.items.count == 1, "恢复原始大小，标注还在")
        if let t = text {
            let r = AnnotationText.rect(for: t)
            var hits = 0
            for y in stride(from: r.minY, to: r.maxY, by: 1) {
                for x in stride(from: r.minX, to: r.maxX, by: 1) {
                    if isRed(pixel(pin.image, x: Int(x * 2), y: Int((150 - y) * 2))) { hits += 1 }
                }
            }
            check(hits > 10, "合成图里文字在它该在的位置")
        }
        pin.closePin()
    }

    // MARK: 剪贴板历史（台阶 4）。全程用私有剪贴板和临时文件夹，不碰你真正的剪贴板和历史

    private static func testClipboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.clip.\(UUID().uuidString)"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-clip-\(UUID().uuidString)")
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        func read() -> Result<ClipboardSnapshot, ClipboardReader.Skip> { ClipboardReader.read(pb, source: nil) }
        func snap() -> ClipboardSnapshot? { if case .success(let s) = read() { return s }; return nil }

        // 1. 读：文字、带格式、图片、文件
        pb.clearContents(); pb.setString("你好 MacKit", forType: .string)
        check(snap()?.kind == .text && snap()?.title == "你好 MacKit", "记文字")
        let rich = NSAttributedString(string: "粗体字", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        pb.clearContents()
        pb.declareTypes([.rtf, .string], owner: nil)
        pb.setData(try? rich.data(from: NSRange(location: 0, length: rich.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        pb.setString("粗体字", forType: .string)
        check(snap()?.kind == .richText, "记带格式的文字（格式也记下）")
        let image = makeTestImage(width: 400, height: 300)
        let png = ImageOutput.pngData(of: image, pointSize: NSSize(width: 200, height: 150)) ?? Data()
        pb.clearContents(); pb.setData(png, forType: .png)
        let img = snap()
        check(img?.kind == .image && img?.imagePixelSize == CGSize(width: 400, height: 300) && img?.title == "图片 400×300",
              "记图片（截图也会记）")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("报告.txt")
        try? "内容".write(to: file, atomically: true, encoding: .utf8)
        pb.clearContents(); pb.writeObjects([file as NSURL])
        check(snap()?.kind == .file && snap()?.title == "报告.txt", "记访达里复制的文件")

        // 2. 不记的：保密、临时、密码管理器、MacKit 自己放回去的、超过 20 MB、空的
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            pb.clearContents()
            pb.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            pb.setString("密码 123456", forType: .string)
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            if case .failure(.ignored) = read() {} else { check(false, "跳过 \(marker)") }
        }
        check(true, "密码管理器复制的（保密 / 临时标记）不记")
        pb.clearContents()
        pb.declareTypes([.string, ClipboardReader.restoreMarker], owner: nil)
        pb.setString("x", forType: .string); pb.setData(Data(), forType: ClipboardReader.restoreMarker)
        if case .failure(.ownRestore) = read() { check(true, "MacKit 自己放回去的不再记一遍") } else { check(false, "MacKit 自己放回去的不再记一遍") }
        pb.clearContents(); pb.setData(Data(count: 21 * 1024 * 1024), forType: NSPasteboard.PasteboardType("public.data"))
        if case .failure(.tooBig) = read() { check(true, "超过 20 MB 的不记") } else { check(false, "超过 20 MB 的不记") }
        pb.clearContents()
        if case .failure(.empty) = read() { check(true, "空剪贴板不记") } else { check(false, "空剪贴板不记") }

        // 3. 存：顺序、去重、置顶、上限、删除、清空、存盘
        let store = ClipboardStore(directory: dir.appendingPathComponent("store"), limit: 5)
        func addText(_ t: String, _ minute: Double) -> ClipboardItem? {
            pb.clearContents(); pb.setString(t, forType: .string)
            guard let s = snap() else { return nil }
            return store.add(s, now: Date(timeIntervalSince1970: 1_800_000_000 + minute * 60))
        }
        let a = addText("甲", 1), b = addText("乙", 2), _ = addText("丙", 3)
        check(store.items.map(\.title) == ["丙", "乙", "甲"], "最新复制的在最上面")
        _ = addText("甲", 4)
        check(store.items.map(\.title) == ["甲", "丙", "乙"] && store.items[0].copyCount == 2 && store.items[0].id == a?.id,
              "同一段复制两次：不多一条，挪到最上面")
        if let b { store.togglePin(b.id) }
        _ = addText("丁", 5)
        check(store.items.map(\.title) == ["乙", "丁", "甲", "丙"] && store.items[0].pinned, "置顶的一直在最上面")
        for (i, t) in ["1", "2", "3", "4", "5", "6"].enumerated() { _ = addText("新\(t)", Double(10 + i)) }
        check(store.unpinnedCount == 5 && store.items.first?.title == "乙", "超过上限删最旧的，置顶的不算、不删")
        pb.clearContents(); pb.setData(png + Data(count: 40 * 1024), forType: .png)      // 大于 32 KB → 单独存成文件
        let big = snap().map { store.add($0) }
        let blobs = dir.appendingPathComponent("store/blobs")
        let blobCount = { (try? FileManager.default.contentsOfDirectory(atPath: blobs.path).count) ?? 0 }
        check(blobCount() >= 1 && big?.pasteboardItems.first?.first?.blob != nil, "大的内容单独存成文件")

        let reloaded = ClipboardStore(directory: dir.appendingPathComponent("store"), limit: 5)
        reloaded.load()
        check(reloaded.items.map(\.id) == store.items.map(\.id), "退出再打开，历史和顺序都在")
        if let entry = reloaded.items.first(where: { $0.id == big?.id })?.pasteboardItems.first?.first {
            check(reloaded.data(of: entry)?.count == png.count + 40 * 1024, "单独存的大内容能读回来")
        }
        if let big { store.delete(big.id) }
        check(blobCount() == 0 && !store.items.contains { $0.id == big?.id }, "删掉一条，它单独存的文件也删掉")
        store.clearUnpinned()
        check(store.items.count == 1 && store.items[0].title == "乙", "清空历史，置顶的保留")

        // 4. 放回剪贴板：原样 / 纯文字 / 文件
        let store2 = ClipboardStore(directory: dir.appendingPathComponent("store2"))
        pb.clearContents(); pb.declareTypes([.rtf, .string], owner: nil)
        pb.setData(try? rich.data(from: NSRange(location: 0, length: rich.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        pb.setString("粗体字", forType: .string)
        guard let richItem = snap().map({ store2.add($0) }) else { check(false, "准备带格式文字"); return }
        ClipboardPaster.write(richItem, plainText: false, store: store2, to: pb)
        check(pb.types?.contains(.rtf) == true && pb.string(forType: .string) == "粗体字", "原样放回：格式还在")
        if case .failure(.ownRestore) = read() { check(true, "放回去的带着 MacKit 的标记，不会再记一遍") } else { check(false, "放回去的带着标记") }
        ClipboardPaster.write(richItem, plainText: true, store: store2, to: pb)
        check(pb.types?.contains(.rtf) == false && pb.string(forType: .string) == "粗体字", "⇧回车：只放纯文字，格式去掉")
        pb.clearContents(); pb.writeObjects([file as NSURL])
        if let fileItem = snap().map({ store2.add($0) }) {
            ClipboardPaster.write(fileItem, plainText: false, store: store2, to: pb)
            check(pb.string(forType: .fileURL).flatMap { URL(string: $0) }?.lastPathComponent == "报告.txt", "文件放回去还是那个文件")
        }

        // 5. 盯剪贴板：变了才读；暂停时不记
        let watchPB = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.watch.\(UUID().uuidString)"))
        defer { watchPB.releaseGlobally() }
        let watcher = ClipboardWatcher(pasteboard: watchPB)
        var seen = 0, paused = false
        watcher.onSnapshot = { _ in seen += 1 }
        watcher.isPaused = { paused }
        watchPB.clearContents(); watchPB.setString("一", forType: .string); watcher.check()
        watcher.check()
        check(seen == 1, "剪贴板变了才记，没变不重复记")
        paused = true
        watchPB.clearContents(); watchPB.setString("二", forType: .string); watcher.check()
        check(seen == 1, "暂停记录时复制的不记")
        paused = false
        watchPB.clearContents(); watchPB.setString("三", forType: .string); watcher.check()
        check(seen == 2, "取消暂停后恢复记录")

        // 6. 小窗口（只造不显示）：搜索、上下选、回车、⌥数字、⌘P、⌘⌫、⌘2
        let tool = ClipboardTool(store: store2, pasteboard: watchPB)
        for (i, t) in ["你好世界", "MacKit 工具箱", "第三条"].enumerated() {
            pb.clearContents(); pb.setString(t, forType: .string)
            if let s = snap() { store2.add(s, now: Date().addingTimeInterval(Double(i))) }
        }
        let panel = tool.makePanel()
        var pasted: [(String, Bool)] = []
        panel.onPaste = { item, plain in pasted.append((item.title, plain)) }
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        defer { panel.close(returnFocus: false) }
        check(ClipboardPanel.visible === panel && panel.shown.count == store2.items.count && panel.selectedIndex == 0,
              "弹出时列出全部，选中第一条")
        panel.searchField.stringValue = "世界"
        panel.reload()
        check(panel.shown.map(\.title) == ["你好世界"], "打字搜索，边打边筛")
        panel.searchField.stringValue = ""
        panel.reload()
        _ = panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        check(panel.selectedIndex == 1, "↓ 选下一条")
        _ = panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(pasted.last.map { $0.0 == panel.shown[1].title && !$0.1 } ?? false, "回车粘贴选中的那条")
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        _ = panel.handleKey(key("2", code: 19, mods: .option))
        check(pasted.last?.0 == panel.shown[1].title, "⌥2 直接粘贴第 2 条")
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        _ = panel.handleKey(key("\r", code: 36, mods: .shift))
        check(pasted.last?.1 == true, "⇧回车 = 只粘贴纯文字")
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        panel.select(2)
        let third = panel.selectedItem
        _ = panel.handleKey(key("p", code: 35, mods: .command))
        check(store2.items.first?.id == third?.id && store2.items.first?.pinned == true && panel.shown.first?.id == third?.id,
              "⌘P 置顶")
        let before = store2.items.count
        panel.select(1)
        _ = panel.handleKey(key("\u{8}", code: 51, mods: .command))
        check(store2.items.count == before - 1, "⌘⌫ 删除选中的那条")
        var pinnedContent: PinContent?
        tool.onPin = { pb in pinnedContent = PinContentReader.read(pb) }
        panel.onPin = { item in tool.makePanel().onPin?(item) }
        panel.select(0)
        panel.requestPin()
        if case .text(let t)? = pinnedContent { check(!t.isEmpty, "⌘2 把选中的那条钉成贴图") } else { check(false, "⌘2 钉成贴图") }
        check(ClipboardPanel.visible == nil, "粘贴或贴图后小窗口关掉")

        let row = ClipboardRowView()
        if let pinned = store2.items.first(where: \.pinned) {
            row.configure(item: pinned, icon: NSImage(), shortcut: "⌥1")
            check(row.titleText.hasPrefix("📌"), "置顶的那条有图钉标记")
        }
        let thumb = ClipboardPanel.thumbnail(png)
        check(thumb != nil && (thumb?.size.width ?? 99) <= 48, "图片在列表里显示成小缩略图")
    }

    // MARK: 录屏（台阶 5）。真的录屏要弹系统窗口、占屏幕，不在这里做；这里测"录哪里、怎么录"算得对不对

    private static func testRecorder(_ tool: RecorderTool) {
        check(tool.state == .idle && tool.hotKeyRegistered, "录屏快捷键 \(Settings.recordHotKey.display) 已注册，平时是空闲状态")
        check(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              "App 里写明了麦克风用途（没写的话一要麦克风权限就会闪退）")
        let titles = tool.menuItems().map(\.title)
        check(titles.contains { $0.hasPrefix("录屏（") } && titles.contains("录屏设置"),
              "菜单里有录屏和录屏设置（画质、保存位置、快捷键、录完自动打开预览）")

        // 选区 → 录哪里
        guard let screen = NSScreen.main else { check(false, "有屏幕"); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let windowCG = CGRect(x: 100, y: 100, width: 400, height: 300)
        let picked = SelectionSession.recordTarget(rect: .zero, picked: 0, screen: screen, sources: [2],
                                                   windowFrames: [.zero, .zero, windowCG], windowIDs: [0, 0, 777])
        check(picked == .window(id: 777, globalFrame: Geometry.cocoaRect(fromCG: windowCG, primaryHeight: primaryHeight)),
              "单击了窗口 → 录这个窗口")
        let whole = SelectionSession.recordTarget(rect: CGRect(origin: .zero, size: screen.frame.size), picked: nil, screen: screen,
                                                  sources: [], windowFrames: [], windowIDs: [])
        if case .display = whole { check(true, "桌面上单击（整块屏幕）→ 录整屏") } else { check(false, "桌面上单击 → 录整屏") }
        let part = CGRect(x: 100, y: 100, width: 300, height: 200)
        let region = SelectionSession.recordTarget(rect: part, picked: nil, screen: screen, sources: [], windowFrames: [], windowIDs: [])
        if case .region(_, _, let r) = region, r == part, region.globalFrame == part.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) {
            check(true, "拖动框选 → 录这一块")
        } else { check(false, "拖动框选 → 录这一块") }

        // 选区视图记下单击的是哪个窗口
        let image = makeTestImage(width: 3024, height: 1964)
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), image: image,
                                 windowRects: [CGRect(x: 300, y: 300, width: 400, height: 200)], scale: 2, hint: "录屏")
        var chosen = 0
        view.onSelect = { _ in chosen += 1 }
        view.mouseDown(with: mouse(.leftMouseDown, 400, 400)); view.mouseUp(with: mouse(.leftMouseUp, 400, 400))
        check(chosen == 1 && view.pickedWindowIndex == 0, "单击窗口：记下选的是这个窗口")
        view.mouseDown(with: mouse(.leftMouseDown, 100, 100))
        view.mouseDragged(with: mouse(.leftMouseDragged, 150, 150))
        view.mouseUp(with: mouse(.leftMouseUp, 200, 200))
        check(chosen == 2 && view.pickedWindowIndex == nil, "拖动框选：不算选了窗口")
        view.mouseDown(with: mouse(.leftMouseDown, 1200, 900)); view.mouseUp(with: mouse(.leftMouseUp, 1200, 900))
        check(chosen == 3 && view.pickedWindowIndex == nil, "桌面上单击：不算选了窗口")

        // 录制参数
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let regionTarget = RecordTarget.region(id: 1, screenFrame: screenFrame, viewRect: CGRect(x: 100, y: 100, width: 401, height: 301))
        let plan = ScreenRecorder.plan(for: regionTarget, quality: .original60, scale: 2, contentSize: screenFrame.size)
        check(plan == RecordPlan(sourceRect: CGRect(x: 100, y: 581, width: 401, height: 301), width: 802, height: 602, fps: 60),
              "录一块区域：只取框里那块，原始清晰度 802×602、每秒 60 帧")
        let full = ScreenRecorder.plan(for: .display(id: 1, screenFrame: screenFrame), quality: .original60, scale: 2,
                                       contentSize: screenFrame.size)
        check(full.sourceRect == nil && full.width == 3024 && full.height == 1964, "录整屏：Retina 原始 3024×1964")
        let small = ScreenRecorder.plan(for: .display(id: 1, screenFrame: screenFrame), quality: .hd30, scale: 2,
                                        contentSize: screenFrame.size)
        check(small.width == 1662 && small.height == 1080 && small.fps == 30, "1080p 档：缩到 1662×1080、每秒 30 帧")
        let win = ScreenRecorder.plan(for: .window(id: 7, globalFrame: .zero), quality: .original60, scale: 2,
                                      contentSize: CGSize(width: 801, height: 600))
        check(win.sourceRect == nil && win.width == 1602 && win.height == 1200, "录窗口：按窗口大小，像素是偶数")

        let config = ScreenRecorder.configuration(plan: plan, options: RecordOptions(systemAudio: true, microphone: false,
                                                                                      quality: .original60))
        check(config.width == 802 && config.height == 602 && config.sourceRect == plan.sourceRect
              && config.minimumFrameInterval == CMTime(value: 1, timescale: 60), "录制设置：尺寸、区域、帧率")
        check(config.capturesAudio && config.excludesCurrentProcessAudio && !config.captureMicrophone && config.showsCursor,
              "录制设置：录系统声音、不录 MacKit 自己的声音、麦克风关、显示鼠标")
        let withMic = ScreenRecorder.configuration(plan: plan, options: RecordOptions(systemAudio: false, microphone: true,
                                                                                       quality: .hd30))
        check(!withMic.capturesAudio && withMic.captureMicrophone, "控制条里关系统声音、开麦克风 → 设置跟着变")

        // 录制前后的界面（只造不显示）
        let bar = RecordingControlBar(systemAudio: true, microphone: false)
        check(bar.buttons.count == 6 && bar.systemAudio && !bar.microphone,
              "控制条：系统声音、麦克风、录多久自动停、几点开始、开始、取消六个按钮")
        let region2 = CGRect(x: 200, y: 200, width: 300, height: 200)
        let border = RecordingBorderWindow(region: region2, screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                           adjustable: false)
        check(border.panel.frame == region2.insetBy(dx: -12, dy: -12) && border.panel.ignoresMouseEvents,
              "红色虚线框画在区域外面、鼠标能穿过去，不会录进画面")
        let hud = RecordingHUD(systemAudio: true, microphone: true)
        var stopped = 0
        hud.onStop = { stopped += 1 }
        hud.update("00:42")
        hud.buttons["stop"]?.performClick(nil)
        check(hud.timeText == "00:42" && stopped == 1 && hud.panel.frame.width > 150 && hud.panel.frame.height >= 36,
              "录制小条：显示时长，点「停止」就停（\(Int(hud.panel.frame.width))×\(Int(hud.panel.frame.height)) 点）")
        check(hud.panel.isMovableByWindowBackground && !hud.panel.canHide, "录制小条能拖走，MacKit 藏起来时它还在")
        var indicator: String? = "x"
        tool.onIndicator = { indicator = $0 }
        tool.reset()
        check(tool.state == .idle && indicator == nil, "取消录屏：回到空闲，菜单栏图标换回扳手")
        tool.onIndicator = nil
    }

    // MARK: 录屏加料第一批（台阶 6）：拼接、剪辑、GIF 用造出来的假视频测；界面只造不显示

    private static func testRecordingExtras(_ tool: RecorderTool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-extras-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4")
        let big = dir.appendingPathComponent("big.mp4")
        let semaphore = DispatchSemaphore(value: 0)
        var results: [String: Any] = [:]
        Task.detached {
            do {
                try await writeTestVideo(to: a, seconds: 1.0, size: CGSize(width: 320, height: 240), hue: 0.0)
                try await writeTestVideo(to: b, seconds: 1.5, size: CGSize(width: 320, height: 240), hue: 0.6)
                try await writeTestVideo(to: big, seconds: 2.0, size: CGSize(width: 1600, height: 900), hue: 0.3)
                let merged = dir.appendingPathComponent("merged.mp4")
                try await VideoTools.concatenate([a, b], to: merged)
                results["merged"] = await VideoTools.duration(of: merged)
                results["mergedTracks"] = (try? await AVURLAsset(url: merged).loadTracks(withMediaType: .video).count) ?? 0
                let trimmed = dir.appendingPathComponent("trimmed.mp4")
                try await VideoTools.trim(merged, range: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                                     end: CMTime(seconds: 2.0, preferredTimescale: 600)), to: trimmed)
                results["trimmed"] = await VideoTools.duration(of: trimmed)
                let gif = dir.appendingPathComponent("big.gif")
                results["gifFrames"] = try await VideoTools.makeGIF(from: big, to: gif)
                if let src = CGImageSourceCreateWithURL(gif as CFURL, nil) {
                    results["gifCount"] = CGImageSourceGetCount(src)
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                    results["gifWidth"] = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                    let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
                    results["gifLoop"] = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int ?? -1
                }
                let gifPart = dir.appendingPathComponent("part.gif")
                results["gifPart"] = try await VideoTools.makeGIF(from: big, range: CMTimeRange(start: .zero,
                                                                  duration: CMTime(seconds: 1, preferredTimescale: 600)), to: gifPart)
            } catch {
                results["error"] = error.localizedDescription
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let e = results["error"] { check(false, "造假视频 / 处理视频出错：\(e)") }
        let merged = results["merged"] as? Double ?? 0
        check(abs(merged - 2.5) < 0.15 && results["mergedTracks"] as? Int == 1,
              "暂停后的几段拼成一个文件：1 秒 + 1.5 秒 = \(String(format: "%.2f", merged)) 秒")
        let trimmed = results["trimmed"] as? Double ?? 0
        check(abs(trimmed - 1.5) < 0.35, "剪掉开头 0.5 秒、只留到 2 秒：剩 \(String(format: "%.2f", trimmed)) 秒")
        check(results["gifFrames"] as? Int == 20 && results["gifCount"] as? Int == 20, "2 秒视频存成 GIF：每秒 10 帧，共 20 帧")
        check(results["gifWidth"] as? Int == 800, "GIF 缩到 800 像素宽（原视频 1600 宽）")
        check(results["gifLoop"] as? Int == 0, "GIF 循环播放")
        check(results["gifPart"] as? Int == 10, "剪过的只转剪好的那段：1 秒 = 10 帧")

        // 录制小条四种样子
        let hud = RecordingHUD(systemAudio: true, microphone: false)
        var calls: [String] = []
        hud.onPause = { calls.append("pause") }
        hud.onResume = { calls.append("resume") }
        hud.onStartNow = { calls.append("startNow") }
        hud.onCancel = { calls.append("cancel") }
        hud.onStop = { calls.append("stop") }
        hud.buttons["pause"]?.performClick(nil)
        hud.setMode(.paused); hud.buttons["resume"]?.performClick(nil)
        hud.setMode(.waiting); hud.buttons["startNow"]?.performClick(nil); hud.buttons["cancel"]?.performClick(nil)
        check(calls == ["pause", "resume", "startNow", "cancel"], "录制小条：暂停、继续、现在开始、取消都能点")
        hud.setMode(.saving)
        check(hud.mode == .saving, "录制小条：保存中")

        // 控制条：录多久自动停、几点开始
        let bar = RecordingControlBar(systemAudio: true, microphone: false)
        bar.setAutoStop(minutes: 5)
        let later = Date().addingTimeInterval(120)
        bar.setStart(at: later)
        check(bar.autoStopMinutes == 5 && bar.startAt == later && bar.buttons.count == 6, "控制条：能选录 5 分钟自动停、2 分钟后开始")

        // 定时流程：设了开始时间 → 等着；取消 → 回到空闲（不显示窗口、不真的录）
        let region = RecordTarget.region(id: 1, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         viewRect: CGRect(x: 100, y: 100, width: 300, height: 200))
        tool.showControlBar(for: region, present: false)
        tool.controlBar?.setStart(at: Date().addingTimeInterval(600))
        tool.startFromBar(region, present: false)
        if case .scheduled(_, let at) = tool.state { check(at > Date(), "设了几点开始 → 先等着，不马上录") } else { check(false, "设了几点开始 → 先等着") }
        let menuTitles = tool.menuItems().map(\.title)
        check(menuTitles.contains("取消定时录制") && menuTitles.contains("现在就开始"), "等着时菜单里能「现在就开始」或「取消定时录制」")
        tool.reset()
        check(tool.state == .idle, "取消定时录制 → 回到空闲")

        // 录制框能调（2026-11-04 第一批验收：录制框不能调大小）
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frameWin = RecordingBorderWindow(region: CGRect(x: 200, y: 200, width: 400, height: 300), screenFrame: screen)
        var changes = 0
        frameWin.onChange = { _ in changes += 1 }
        check(frameWin.beginDrag(at: CGPoint(x: 600, y: 200)), "鼠标在右下角小方块上 → 开始改大小")
        frameWin.drag(to: CGPoint(x: 700, y: 150)); frameWin.endDrag()
        check(frameWin.region == CGRect(x: 200, y: 150, width: 500, height: 350) && changes == 1, "拖右下角：框变大，左上角不动")
        check(frameWin.beginDrag(at: CGPoint(x: 300, y: 500)), "鼠标在上边虚线上（不是小方块）→ 开始挪位置")
        frameWin.drag(to: CGPoint(x: 320, y: 480)); frameWin.endDrag()
        check(frameWin.region == CGRect(x: 220, y: 130, width: 500, height: 350), "拖虚线：整个框挪过去，大小不变")
        check(!frameWin.beginDrag(at: CGPoint(x: 450, y: 300)), "框里面不算拖框（照常能点下面的软件）")
        frameWin.beginDrag(at: CGPoint(x: 220, y: 300)); frameWin.drag(to: CGPoint(x: -500, y: 300)); frameWin.endDrag()
        check(frameWin.region.minX == 0, "挪出屏幕外 → 停在屏幕边上")
        frameWin.beginDrag(at: CGPoint(x: frameWin.region.maxX, y: frameWin.region.midY))
        frameWin.drag(to: CGPoint(x: frameWin.region.minX + 5, y: frameWin.region.midY)); frameWin.endDrag()
        check(frameWin.region.width >= 40, "缩得太小 → 最小 40 点宽")
        frameWin.setAdjustable(false)
        check(!frameWin.beginDrag(at: CGPoint(x: frameWin.region.maxX, y: frameWin.region.maxY)) && frameWin.panel.ignoresMouseEvents,
              "开始倒数后框锁定，不能再调")
        let chosen = RecordTarget.region(id: 1, screenFrame: CGRect(x: 1728, y: 0, width: 1512, height: 982),
                                         viewRect: CGRect(x: 10, y: 10, width: 100, height: 100))
        if case .region(_, _, let r) = RecorderTool.adjusted(chosen, to: CGRect(x: 1828, y: 50, width: 300, height: 200)) {
            check(r == CGRect(x: 100, y: 50, width: 300, height: 200), "按调好的框录（换算回这块屏幕的坐标）")
        } else { check(false, "按调好的框录") }
        if case .window = RecorderTool.adjusted(.window(id: 9, globalFrame: .zero), to: CGRect(x: 0, y: 0, width: 10, height: 10)) {
            check(true, "录窗口不受红框影响")
        } else { check(false, "录窗口不受红框影响") }

        // 预览窗口（只造不显示）
        let preview = RecordingPreviewWindow(url: a)
        preview.show(present: false)
        preview.setTrim(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)))
        check(preview.buttons.keys.sorted() == ["delete", "gif", "reveal", "save", "trim"] && preview.trimRange != nil,
              "预览窗口：剪辑、保存、存成 GIF、在访达中显示、删掉")
        preview.window.close()
    }

    /// 造一段纯色渐变的假视频（H.264、没有声音）
    nonisolated private static func writeTestVideo(to url: URL, seconds: Double, size: CGSize, hue: CGFloat) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let shade = UInt8(40 + (i * 5) % 200)
                let blue = UInt8(min(255, Int(hue * 255)))
                let bytes = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for j in stride(from: 0, to: bytes, by: 4) { p[j] = blue; p[j + 1] = shade; p[j + 2] = 255 - shade; p[j + 3] = 255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VideoToolError.exportUnavailable }
    }

    // MARK: 工具

    private static func key(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                         keyCode: code)!
    }

    private static func scrollEvent(lines: Int32, option: Bool) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
        if option { cg.flags = .maskAlternate }
        return NSEvent(cgEvent: cg)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
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

/// 录屏冒烟测试：MacKit --record-smoke <结果文件>
/// 真的录（不弹任何窗口、不开麦克风）：屏幕左上角一小块 2 秒、最前面的一个窗口 1.5 秒、整屏 1.5 秒，
/// 再录两段各 1.5 秒拼起来（模拟暂停）并转成 GIF。
/// 检查生成的 mp4 能不能读、尺寸时长对不对，然后删掉视频。要用 open 启动（这样"录屏权限"算在 MacKit 头上）
@MainActor
enum RecordSmokeTest {
    static func run(resultPath: String) {
        Task { @MainActor in
            var lines: [String] = []
            var allOK = true
            guard let screen = NSScreen.screens.first, let id = screen.displayID else { finish(["没有屏幕"], false, resultPath); return }
            let scale = screen.backingScaleFactor

            let viewRect = CGRect(x: 40, y: screen.frame.height - 40 - 150, width: 200, height: 150)
            let r1 = await record(.region(id: id, screenFrame: screen.frame, viewRect: viewRect), seconds: 2)
            lines.append("区域：" + r1.text)
            allOK = allOK && r1.ok && r1.size == CGSize(width: 200 * scale, height: 150 * scale) && r1.audio == 1

            if let w = WindowList.current().first(where: { $0.frame.width >= 200 && $0.frame.height >= 150 }) {
                let r2 = await record(.window(id: w.id, globalFrame: .zero), seconds: 1.5)
                lines.append("窗口：" + r2.text + "（窗口 \(Int(w.frame.width))×\(Int(w.frame.height)) 点）")
                let expect = CGSize(width: CGFloat(Int(w.frame.width * scale) / 2 * 2), height: CGFloat(Int(w.frame.height * scale) / 2 * 2))
                allOK = allOK && r2.ok && abs(r2.size.width - expect.width) <= 2 && abs(r2.size.height - expect.height) <= 2
            } else {
                lines.append("窗口：没有可录的窗口，跳过")
            }

            let r3 = await record(.display(id: id, screenFrame: screen.frame), seconds: 1.5)
            lines.append("整屏：" + r3.text)
            allOK = allOK && r3.ok && r3.size == CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)

            // 暂停再继续 = 录两段再拼起来；再转成 GIF
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-smoke-pause-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let target = RecordTarget.region(id: id, screenFrame: screen.frame, viewRect: viewRect)
            var parts: [URL] = []
            for i in 1...2 {
                let url = dir.appendingPathComponent("part-\(i).mp4")
                let r = ScreenRecorder(url: url)
                do {
                    try await r.start(target: target, options: RecordOptions(systemAudio: true, microphone: false, quality: .original60),
                                      excluding: [])
                    try? await Task.sleep(for: .seconds(1.5))
                    await r.stop()
                    parts.append(url)
                } catch { lines.append("暂停拼接：第 \(i) 段没录成（\(error.localizedDescription)）") }
                try? await Task.sleep(for: .seconds(0.5))           // 暂停的这半秒不该进视频
            }
            let merged = dir.appendingPathComponent("merged.mp4")
            do {
                try await VideoTools.concatenate(parts, to: merged)
                let d = await VideoTools.duration(of: merged)
                let audio = (try? await AVURLAsset(url: merged).loadTracks(withMediaType: .audio).count) ?? 0
                lines.append("暂停拼接：两段各 1.5 秒 → \(String(format: "%.2f", d)) 秒，声音轨 \(audio)")
                allOK = allOK && parts.count == 2 && abs(d - 3.0) < 0.6 && audio >= 1
                let gif = dir.appendingPathComponent("merged.gif")
                let frames = try await VideoTools.makeGIF(from: merged, to: gif)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
                lines.append("存成 GIF：\(frames) 帧，\(bytes) 字节")
                allOK = allOK && frames >= 25 && bytes > 0
            } catch {
                lines.append("暂停拼接失败：\(error.localizedDescription)")
                allOK = false
            }
            finish(lines, allOK, resultPath)
        }
    }

    private static func finish(_ lines: [String], _ ok: Bool, _ path: String) {
        try? (lines + [ok ? "SMOKE OK" : "SMOKE FAILED"]).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    private struct Outcome { var ok: Bool; var size: CGSize; var audio: Int; var text: String }

    private static func record(_ target: RecordTarget, seconds: Double) async -> Outcome {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("smoke.mp4")
        let recorder = ScreenRecorder(url: url)
        var failure: Error?
        recorder.onFinished = { if case .failure(let e) = $0 { failure = e } }
        do {
            try await recorder.start(target: target, options: RecordOptions(systemAudio: true, microphone: false,
                                                                            quality: .original60), excluding: [])
            try? await Task.sleep(for: .seconds(seconds))
            await recorder.stop()
        } catch {
            return Outcome(ok: false, size: .zero, audio: 0, text: "开始录制失败：\(error.localizedDescription)")
        }
        let asset = AVURLAsset(url: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var dims = CGSize.zero
        if let v = video.first, let natural = try? await v.load(.naturalSize) { dims = natural }
        let text = "文件 \(bytes) 字节，视频轨 \(video.count)，声音轨 \(audio.count)，时长 \(String(format: "%.2f", duration)) 秒，画面 \(Int(dims.width))×\(Int(dims.height))"
            + (failure.map { "，报错：\($0.localizedDescription)" } ?? "")
        return Outcome(ok: bytes > 0 && video.count == 1 && duration > seconds * 0.6 && failure == nil,
                       size: dims, audio: audio.count, text: text)
    }
}

