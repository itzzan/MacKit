import AppKit
import AVFoundation
import CoreImage
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
        testSelectEdit()
        testBeautify()
        testPinTransforms()
        testTextEditing()
        testPinAnnotation()
        testClipboard()
        testRecorder(recorder)
        testRecordingExtras(recorder)
        testRecordingOverlays(recorder)
        testRecognize()
        testLongShot(menu: statusItem.menu)
        testMisc(menu: statusItem.menu, recorder: recorder)
        testTheme()
        testMenuLayout(statusItem.menu)
        testIconAndWindows()
        testRelease(statusItem.menu)

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
        // 台阶 12 起按在画好的东西上 = 选中它，所以每样从空白处起笔
        for (k, tool) in [AnnotationTool.ellipse, .arrow, .pen, .highlighter, .mosaic, .blur].enumerated() {
            editor.selectTool(tool)
            let x = CGFloat(220 + k * 70)
            view.mouseDown(with: mouse(.leftMouseDown, x, 260))
            view.mouseDragged(with: mouse(.leftMouseDragged, x + 25, 270))
            view.mouseUp(with: mouse(.leftMouseUp, x + 50, 280))
        }
        check(editor.document.items.count == count + 6, "椭圆、箭头、画笔、荧光笔、马赛克、模糊各画一下")
        check(Set(editor.document.items.map(\.tool)) == Set(AnnotationTool.allCases), "九种工具都画上了")

        editor.selectTool(nil)
        view.keyDown(with: key("\r", code: 36))
        check(done == 1, "回车 = 完成")
        view.mouseDown(with: mouse(.leftMouseDown, 660, 560, clicks: 2))
        check(done == 2, "没选工具时在框里空白处双击 = 完成")
        view.keyDown(with: key("\u{1b}", code: 53))
        check(cancelled == 0 && editor.selectedIndex == nil, "刚画完的还选着：第一下 Esc 只是取消选中")
        view.keyDown(with: key("\u{1b}", code: 53))
        check(cancelled == 1, "再按 Esc = 取消截图")

        if let rect = view.currentSelection,
           let out = AnnotationExporter.export(image: image, viewSize: viewSize, selection: rect, screenOrigin: .zero,
                                               annotations: editor.document.items,
                                               mosaic: MosaicSource(image: image, viewSize: viewSize)) {
            check(out.image.width == Int(rect.width * 2), "编辑完导出，尺寸和框一致")
        } else { check(false, "编辑完导出") }
    }

    // MARK: 文字工具：拼音看得见、写好的字能再改（2026-11-04 用户验收时提的两个问题）

    /// 台阶 12：点一下画好的东西就选中，能拖、能改大小、能换颜色、能删；模糊打码
    private static func testSelectEdit() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        let mosaic = MosaicSource(image: image, viewSize: viewSize)
        let editor = AnnotationEditor(container: container, mosaic: mosaic)
        defer { editor.tearDown() }
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.beginEditing(editor, selection: CGRect(x: 100, y: 100, width: 800, height: 600))
        editor.setColor(.red)
        editor.setSize(.medium)
        func drag(_ from: CGPoint, _ to: CGPoint) {
            view.mouseDown(with: mouse(.leftMouseDown, from.x, from.y))
            view.mouseDragged(with: mouse(.leftMouseDragged, (from.x + to.x) / 2, (from.y + to.y) / 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, to.x, to.y))
            view.mouseUp(with: mouse(.leftMouseUp, to.x, to.y))
        }

        view.keyDown(with: key("r", code: 15))
        drag(CGPoint(x: 200, y: 200), CGPoint(x: 400, y: 300))
        check(editor.document.items.count == 1 && editor.selectedIndex == 0 && editor.canvas.selectionLook?.handles.count == 8,
              "画完一个框：自动选中，四周 8 个小方块")
        editor.selectTool(nil)
        view.mouseDown(with: mouse(.leftMouseDown, 650, 600)); view.mouseUp(with: mouse(.leftMouseUp, 650, 600))
        check(editor.selectedIndex == nil && editor.canvas.selectionLook == nil, "点空白处：取消选中")
        view.mouseDown(with: mouse(.leftMouseDown, 300, 250)); view.mouseUp(with: mouse(.leftMouseUp, 300, 250))
        check(editor.selectedIndex == nil, "点框里面的空白：不算点中框")
        check(editor.editCursor(at: CGPoint(x: 201, y: 250)) == .pointingHand && editor.editCursor(at: CGPoint(x: 300, y: 250)) == nil,
              "鼠标在框的线上变小手，框中间不变")

        drag(CGPoint(x: 200, y: 250), CGPoint(x: 230, y: 240))
        check(editor.selectedIndex == 0 && editor.document.items[0].box == CGRect(x: 230, y: 190, width: 200, height: 100),
              "点住框的线拖：整个框挪过去")
        editor.undo()
        check(editor.document.items[0].box == CGRect(x: 200, y: 200, width: 200, height: 100), "拖一次 = 撤销一步，回到原处")
        editor.redo()
        view.mouseDown(with: mouse(.leftMouseDown, 230, 240)); view.mouseUp(with: mouse(.leftMouseUp, 230, 240))
        drag(CGPoint(x: 434, y: 294), CGPoint(x: 484, y: 344))
        check(editor.document.items[0].box == CGRect(x: 230, y: 190, width: 250, height: 150), "拖右上角的小方块：框变大，不会一按就跳")
        check(editor.toolbar.isShowingProperties, "没选工具、但选中了东西：工具栏露出颜色和粗细")
        editor.setColor(.blue)
        editor.setSize(.thick)
        check(editor.document.items[0].color == .blue && editor.document.items[0].size == .thick, "选中时点颜色、粗细：改的是它")
        editor.undo()
        check(editor.document.items[0].size == .medium, "改粗细也能撤销")
        view.mouseDown(with: mouse(.leftMouseDown, 230, 240)); view.mouseUp(with: mouse(.leftMouseUp, 230, 240))
        view.keyDown(with: key("", code: 124))
        check(editor.document.items[0].box.minX == 231, "选中时按方向键：挪 1 点")
        view.keyDown(with: key("\u{7f}", code: 51))
        check(editor.document.items.isEmpty, "按 ⌫：删掉选中的")
        editor.undo()
        check(editor.document.items.count == 1, "⌘Z：删掉的回来")

        view.keyDown(with: key("a", code: 0))
        drag(CGPoint(x: 500, y: 450), CGPoint(x: 600, y: 500))
        check(editor.selectedIndex == 1 && editor.canvas.selectionLook?.round == true && editor.canvas.selectionLook?.handles.count == 2,
              "箭头选中后只有头尾两个小圆点")
        drag(CGPoint(x: 600, y: 500), CGPoint(x: 650, y: 450))
        check(editor.document.items[1].points.first == CGPoint(x: 500, y: 450) && editor.document.items[1].points.last == CGPoint(x: 650, y: 450),
              "拖箭头的尖：方向和长短跟着变，尾巴不动")

        view.keyDown(with: key("p", code: 35))
        view.mouseDown(with: mouse(.leftMouseDown, 200, 500))
        view.mouseDragged(with: mouse(.leftMouseDragged, 220, 520))
        view.mouseUp(with: mouse(.leftMouseUp, 240, 540))
        drag(CGPoint(x: 244, y: 544), CGPoint(x: 284, y: 584))
        check(EditGeometry.bounds(of: editor.document.items[2].points) == CGRect(x: 200, y: 500, width: 80, height: 80)
              && editor.document.items[2].points.last == CGPoint(x: 280, y: 580), "拖画笔的小方块：整笔等比例变大")

        view.keyDown(with: key("n", code: 45))
        view.mouseDown(with: mouse(.leftMouseDown, 700, 600)); view.mouseUp(with: mouse(.leftMouseUp, 700, 600))
        let numbers = editor.document.items.filter { $0.tool == .number }.count
        view.mouseDown(with: mouse(.leftMouseDown, 702, 601)); view.mouseUp(with: mouse(.leftMouseUp, 702, 601))
        check(editor.document.items.filter { $0.tool == .number }.count == numbers, "序号工具点在已有的序号上：选中它，不会再放一个")

        view.keyDown(with: key("\u{1b}", code: 53))
        check(cancelled == 0 && editor.selectedIndex == nil, "有选中的时候按 Esc：只取消选中")
        view.keyDown(with: key("\u{1b}", code: 53))
        check(cancelled == 1, "再按 Esc：取消截图")

        // 模糊：框住蓝块的右边缘（视图里蓝块在 x 100–200、y 782–882）
        let blur = Annotation(tool: .blur, color: .red, size: .medium, points: [CGPoint(x: 150, y: 760), CGPoint(x: 250, y: 860)])
        let crop = CGRect(x: 50, y: 650, width: 400, height: 300)
        if let plain = AnnotationExporter.export(image: image, viewSize: viewSize, selection: crop, screenOrigin: .zero,
                                                 annotations: [], mosaic: mosaic),
           let blurred = AnnotationExporter.export(image: image, viewSize: viewSize, selection: crop, screenOrigin: .zero,
                                                   annotations: [blur], mosaic: mosaic) {
            let edgeBefore = pixel(plain.image, x: 296, y: 260), edgeAfter = pixel(blurred.image, x: 296, y: 260)
            let farBefore = pixel(plain.image, x: 140, y: 480), farAfter = pixel(blurred.image, x: 140, y: 480)
            check(abs(edgeAfter.b - edgeBefore.b) + abs(edgeAfter.r - edgeBefore.r) > 30 && farAfter == farBefore,
                  "模糊：框里蓝块的边糊开了（\(edgeBefore) → \(edgeAfter)），框外一点不变")
        } else {
            check(false, "模糊导出")
        }
        check(AnnotationTool.forKey("b") == .blur && editor.toolbar.toolButtons[.blur] != nil, "工具栏有\u{201C}模糊\u{201D}，快捷键 B")
    }

    /// 台阶 13：截图美化
    private static func testBeautify() {
        let image = makeTestImage(width: 400, height: 300)
        let size = CGSize(width: 200, height: 150)
        // 美化窗口会记住样式：先存下你的设置，测完原样放回去
        let keys = ["beautify.background", "beautify.padding", "beautify.corner", "beautify.shadow"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }

        if let out = BeautifyRenderer.render(image, pointSize: size, style: .standard, scale: 2) {
            let corner = pixel(out, x: 3, y: 3), center = pixel(out, x: out.width / 2, y: out.height / 2)
            let source = pixel(image, x: 200, y: 150)
            check(out.width == 512 && out.height == 412 && corner.b > 200 && corner.r < 140 && center == source,
                  "美化：四周加 28 点留白（\(out.width)×\(out.height)），角上是蓝紫渐变，中间是截图原样")
        } else { check(false, "美化画得出来") }
        var none = BeautifyStyle.standard
        none.background = .none
        if let out = BeautifyRenderer.render(image, pointSize: size, style: none, scale: 2) {
            check(pixelAlpha(out, x: 1, y: 1) == 0 && pixelAlpha(out, x: out.width / 2, y: out.height / 2) == 255,
                  "美化选\u{201C}不要背景\u{201D}：四周透明，截图不透明")
        }
        var square = BeautifyStyle.standard
        square.corner = .large
        if let out = BeautifyRenderer.render(image, pointSize: size, style: square, scale: 2) {
            let l = BeautifyMath.layout(imageSize: size, style: square).image
            let cornerPx = pixel(out, x: Int(l.minX * 2) + 1, y: Int((BeautifyMath.layout(imageSize: size, style: square).canvas.height - l.maxY) * 2) + 1)
            check(cornerPx != pixel(image, x: 0, y: 0), "大圆角：截图的角被切掉，露出背景")
        }

        let w = BeautifyWindow(image: image, pointSize: size, style: .standard)
        check(w.preview.image != nil && w.swatches.count == 10 && w.swatches[0].isSelectedLook, "美化窗口：有预览、8 种渐变 + 自动 + 无，默认选中蓝紫")
        w.swatches[9].performClick(nil)
        check(w.style.background == .none && Settings.beautifyStyle.background == .none && w.swatches[9].isSelectedLook,
              "点\u{201C}无\u{201D}：换成不要背景，并记住")
        let before = w.preview.image?.size ?? .zero
        w.paddingControl.selectedSegment = 2
        w.shadowBox.state = .off
        w.controlsChanged()
        check(w.style.padding == .large && !w.style.shadow && Settings.beautifyStyle.padding == .large
              && (w.preview.image?.size ?? .zero) != before, "改留白、关阴影：预览马上跟着变，样式记住了")
        var got: CGSize?
        w.onDone = { _, s in got = s }
        w.done()
        check(got == BeautifyMath.layout(imageSize: size, style: w.style).canvas, "点完成：交出原图清晰度的美化图")
        let again = BeautifyWindow(image: image, pointSize: size, style: Settings.beautifyStyle)
        check(again.style.padding == .large && again.style.background == .none, "下次打开：还是上次挑的样式")

        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.beautify.\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitBeautify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); pb.releaseGlobally() }
        if let r = again.result(), let out = BeautifyTool.output(r.image, pointSize: r.pointSize, pasteboard: pb, folder: folder) {
            check(out.saved && pb.data(forType: .png) != nil, "美化完成：复制到剪贴板，同时存成 PNG")
        } else { check(false, "美化完成能复制保存") }

        // 截图工具栏的"美化"按钮
        let viewSize = CGSize(width: 1512, height: 982)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: makeTestImage(width: 3024, height: 1964), viewSize: viewSize))
        var beautified = 0
        editor.onBeautify = { beautified += 1 }
        findButton(in: editor.toolbar) { $0.toolTip?.hasPrefix("美化") == true }?.performClick(nil)
        check(beautified == 1, "截图工具栏有\u{201C}美化\u{201D}按钮")
        editor.tearDown()
    }

    /// 台阶 13：贴图转、翻、裁、撤回，找回关掉的贴图
    private static func testPinTransforms() {
        let image = makeTestImage(width: 400, height: 300)
        let pin = PinWindow(image: image, pointSize: NSSize(width: 200, height: 150), frame: CGRect(x: 100, y: 100, width: 200, height: 150), scale: 1)
        pin.document.add(Annotation(tool: .rect, color: .green, size: .medium, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)]))
        pin.restoreAnnotations(pin.document.checkpoint())
        let annotated = pin.image

        pin.transform(.rotateRight)
        check(pin.basePointSize == NSSize(width: 150, height: 200) && pin.image.width == 300 && pin.image.height == 400
              && pin.document.items.isEmpty && pin.frame == CGRect(x: 125, y: 75, width: 150, height: 200),
              "贴图向右转：宽高对调、以中心为准，标注压进了图里")
        pin.pinView?.keyDown(with: key("1", code: 18))
        check(pin.basePointSize == NSSize(width: 200, height: 150) && pixel(pin.image, x: 10, y: 10) == pixel(annotated, x: 10, y: 10),
              "按 1 再向左转：转回原来的方向")
        pin.undoTransform()
        pin.undoTransform()
        check(pin.basePointSize == NSSize(width: 200, height: 150) && pin.document.items.count == 1 && pin.originalImage === image
              && pin.frame == CGRect(x: 100, y: 100, width: 200, height: 150), "⌘Z 两次：回到转之前，标注回来、还能改")

        pin.pinView?.keyDown(with: key("3", code: 20))
        let blueBefore = pixel(annotated, x: 300, y: 300), blueAfter = pixel(pin.image, x: 99, y: 300)
        check(blueAfter == blueBefore, "按 3 左右翻：右边的蓝块翻到左边")
        _ = pin.pinView?.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(pin.document.items.count == 1 && !pin.canUndoTransform, "贴图上按 ⌘Z：撤回翻转")

        pin.beginCrop(present: false)
        check(pin.isCropping && pin.cropView?.cropRect == CGRect(x: 0, y: 0, width: 200, height: 150), "右键裁剪：出现框，一开始是整张")
        pin.endCrop(nil)
        check(!pin.isCropping && pin.basePointSize == NSSize(width: 200, height: 150), "裁剪时按 Esc：不裁了")
        pin.beginCrop(present: false)
        pin.cropView?.setCrop(CGRect(x: 50, y: 25, width: 100, height: 75))
        pin.endCrop(pin.cropView?.cropRect)
        check(pin.basePointSize == NSSize(width: 100, height: 75) && pin.image.width == 200
              && pin.frame == CGRect(x: 150, y: 125, width: 100, height: 75), "裁剪：只留中间那块，留下的部分在屏幕上不挪地方")
        let titles = pin.makeContextMenu().items.map(\.title)
        check(titles.contains("美化…") && titles.contains("旋转和翻转") && titles.contains("裁剪") && titles.contains("撤回上一次转 / 翻 / 裁"),
              "贴图右键：美化、旋转和翻转、裁剪、撤回")
        pin.undoTransform()

        // 找回关掉的贴图
        let tool = PinTool()
        tool.remember(pin)
        check(tool.closed.count == 1 && tool.menuItems().contains { $0.title == "找回关掉的贴图（1 张）" }, "关掉一张：菜单里能找回")
        guard let back = tool.reopen(at: 0, present: false) else { check(false, "找回贴图"); return }
        check(back.frame == pin.frame && back.basePointSize == pin.basePointSize && back.document.items.count == 1
              && tool.closed.isEmpty && tool.pins.count == 1, "找回：原来的位置、大小，标注也在")
        back.closePin()
        check(tool.closed.count == 1 && tool.pins.isEmpty, "再关掉：又进了找回列表")
        for _ in 0..<25 { tool.remember(pin) }
        check(tool.closed.count == PinTool.closedLimit, "最多记 20 张")
        tool.clearClosed()
        check(tool.closed.isEmpty && PinTool.thumbSize(NSSize(width: 480, height: 160)) == NSSize(width: 48, height: 16), "清空列表；菜单小图等比例")
    }

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
        check(pin.isAnnotating && second.editor.selectedIndex == nil, "贴图标注：刚画完的选着，第一下 Esc 只取消选中")
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
        let settingTitles = tool.settingsItems().map(\.title)
        check(titles.contains { $0.hasPrefix("录屏（") } && settingTitles.contains { $0.hasPrefix("画质：") }
              && settingTitles.contains("录完自动打开预览") && settingTitles.contains("更改保存位置…")
              && settingTitles.contains { $0.hasPrefix("快捷键 ") },
              "菜单里有录屏，录屏设置里有画质、保存位置、快捷键、录完自动打开预览")

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
        check(bar.buttons.count == 9 && bar.systemAudio && !bar.microphone,
              "控制条：系统声音、麦克风、点击、按键、摄像头、录多久自动停、几点开始、开始、取消九个按钮")
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
        check(bar.autoStopMinutes == 5 && bar.startAt == later && bar.buttons.count == 9, "控制条：能选录 5 分钟自动停、2 分钟后开始")

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

    // MARK: 录屏加料第二批：点击高亮、按键显示、摄像头。不打开摄像头、不监听按键、不改你的设置

    private static func testRecordingOverlays(_ tool: RecorderTool) {
        check(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil, "App 里写明了摄像头用途（没写一要权限就闪退）")

        let bar = RecordingControlBar(systemAudio: true, microphone: false, showClicks: true, showKeys: true, camera: false,
                                      windowTarget: true)
        check(bar.buttons.count == 9 && bar.showClicks && bar.showKeys && !bar.camera,
              "控制条多了 🖱 点击、⌨ 按键、📷 摄像头三个开关（共 9 个按钮）")
        check(bar.showsWindowHint, "录单个窗口时开了按键：控制条上提示录不进去")
        let regionBar = RecordingControlBar(systemAudio: true, microphone: false, showClicks: true, showKeys: true, camera: true,
                                            windowTarget: false)
        check(!regionBar.showsWindowHint, "框选区域时不提示")
        let plainBar = RecordingControlBar(systemAudio: true, microphone: false, windowTarget: true)
        check(!plainBar.showsWindowHint, "录窗口但没开按键和摄像头：不提示")
        plainBar.setCamera(true)
        check(plainBar.camera && plainBar.showsWindowHint, "录窗口时打开摄像头：出现提示")

        let plan = RecordPlan(sourceRect: nil, width: 800, height: 600, fps: 60)
        let on = ScreenRecorder.configuration(plan: plan, options: RecordOptions(systemAudio: true, microphone: false,
                                                                                  quality: .original60, showClicks: true))
        let off = ScreenRecorder.configuration(plan: plan, options: RecordOptions(systemAudio: true, microphone: false,
                                                                                   quality: .original60))
        check(on.showMouseClicks && !off.showMouseClicks, "🖱 开着 → 录出来的视频里点击处画圈（macOS 15 自带）")
        check(on.pixelFormat == kCVPixelFormatType_32BGRA, "画面格式是 BGRA（点击画圈要求的）")

        let cast = KeyCastWindow()
        for k in ["⌘ C", "⌘ V", "↩", "⇧ ⌘ 4"] { cast.show(k, present: false) }
        check(cast.displayedText == "⌘ V　↩　⇧ ⌘ 4", "按键牌子：连着按的排成一行，最多 3 个")
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "$", charactersIgnoringModifiers: "$", isARepeat: false, keyCode: 21)!
        check(KeyFormatter.text(keyCode: ev.keyCode, modifiers: KeyCaster.modifiers(ev.modifierFlags),
                                characters: ev.charactersIgnoringModifiers) == "⇧ ⌘ 4", "真的按键事件 ⇧⌘4 → 牌子上是「⇧ ⌘ 4」")
        cast.close()

        // 测完原样恢复：原来没有这两项设置就删掉
        let store = UserDefaults.standard
        let savedSide = store.object(forKey: "record.cameraSide"), savedRounded = store.object(forKey: "record.cameraRounded")
        defer {
            if let savedSide { store.set(savedSide, forKey: "record.cameraSide") } else { store.removeObject(forKey: "record.cameraSide") }
            if let savedRounded { store.set(savedRounded, forKey: "record.cameraRounded") } else { store.removeObject(forKey: "record.cameraRounded") }
        }
        let bubble = CameraBubble(side: 180, rounded: false)
        check(bubble.view.layer?.cornerRadius == 90 && bubble.view.layer?.masksToBounds == true, "摄像头画面默认是圆形")
        bubble.setRounded(true)
        check(bubble.rounded && bubble.view.layer?.cornerRadius == 18, "右键能换成圆角方形")
        bubble.place(CGRect(x: 500, y: 500, width: 180, height: 180))
        bubble.setSide(260)
        check(bubble.side == 260 && abs(bubble.panel.frame.midX - 590) < 0.5, "换成大号，中心不动")
        bubble.setSide(1000)
        check(bubble.side == 400, "最大 400 点")
        let titles = bubble.makeMenu().items.map(\.title)
        check(titles.contains { $0.hasPrefix("小") } && titles.contains("圆形") && titles.contains("圆角方形") && titles.contains("关掉摄像头"),
              "摄像头右键菜单：大小、形状、关掉")
        bubble.close()

        tool.showControlBar(for: .window(id: 1, globalFrame: CGRect(x: 0, y: 0, width: 400, height: 300)), present: false)
        check(tool.controlBar?.windowTarget == true, "录窗口时控制条知道是窗口")
        tool.reset()
    }

    // MARK: 识别工具（台阶 7）：识别文字、二维码、剪贴板搜图、取色、测量

    /// 等一个异步结果（自检里用，最多等 timeout 秒）
    private static func awaitResult<T>(timeout: Double = 20, _ work: @escaping @MainActor () async -> T) -> T? {
        var result: T?
        Task { @MainActor in result = await work() }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result
    }

    private static func testRecognize() {
        // 1. 识别文字：用 MacKit 自己画的文字卡片
        if let card = TextCard.render("你好 MacKit\nHello World 123\nlet tool = ScreenshotTool()", scale: 2),
           let result = awaitResult({ await TextRecognizer.recognize(card.image) }) {
            let all = result.text
            // 大小写不比：系统会把 MacKit 认成 Mackit（2026-11-04 实测，是系统识别本身的局限）
            check(all.contains("你好") && all.lowercased().contains("mackit") && all.contains("Hello World"),
                  "识别文字：中文、英文都认得（认出：\(all.replacingOccurrences(of: "\n", with: " / "))）")
            check(result.lines.count == 3 && result.lines.first?.contains("你好") == true, "识别文字：从上到下一行行排好")
            check(result.lines.last?.contains("()") == true, "代码里的括号是半角 ()，不是全角（）")
        } else { check(false, "识别文字卡片") }

        // 2. 二维码
        if let qr = makeQRCode("https://example.com/mackit"), let result = awaitResult({ await TextRecognizer.recognize(qr) }) {
            check(result.codes.first == "https://example.com/mackit", "识别二维码：读出里面的网址")
            let w = OCRResultWindow(result: result)
            check(w.buttons["open"]?.isHidden == false && w.buttons["copyCode"]?.isHidden == false, "二维码是网址 → 结果窗口有「打开链接」")
            w.window.close()
        } else { check(false, "识别二维码") }

        // 3. 结果窗口
        let w = OCRResultWindow(result: OCRResult(lines: ["第一行", "second line"], codes: []))
        check(w.textView.string == "第一行\nsecond line" && w.buttons["open"]?.isHidden == true, "结果窗口：显示识别出的字，没有二维码就没有「打开链接」")
        w.joinLines()
        check(w.textView.string == "第一行second line", "结果窗口：「去掉换行」接成一段")
        check(w.window is EditableWindow, "结果窗口里 ⌘C ⌘V ⌘A ⌘Z 能用、⌘W 能关")
        w.window.close()

        // 4. 剪贴板历史里的图片：识别后能搜到里面的字（私有剪贴板、临时文件夹）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-ocr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.ocr.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let store = ClipboardStore(directory: dir)
        if let card = TextCard.render("剪贴板里的截图 Screenshot", scale: 2),
           let png = ImageOutput.pngData(of: card.image, pointSize: card.pointSize) {
            pb.clearContents(); pb.setData(png, forType: .png)
            if case .success(let snap) = ClipboardReader.read(pb, source: nil) {
                let item = store.add(snap)
                ClipboardTool(store: store, pasteboard: pb).recognizeText(in: item)
                let found = awaitResult(timeout: 15) { () -> Bool in
                    for _ in 0..<150 {
                        if store.items.first?.searchText.contains("剪贴板") == true { return true }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    return false
                } ?? false
                check(found && ClipboardText.matches("Screenshot", in: store.items.first?.searchText ?? ""),
                      "剪贴板历史里的截图：识别完能按图里的字搜到")
            } else { check(false, "读剪贴板图片") }
        }

        // 5. 取色：截图时的放大镜
        let image = makeTestImage(width: 3024, height: 1964)
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), image: image, windowRects: [], scale: 2)
        var picked: String?
        view.onColorPick = { picked = $0 }
        view.updateMagnifier(at: CGPoint(x: 150, y: 832))           // 蓝块里（像素 300, 300）
        let expected = PixelBuffer(image: image)?.rgb(300, 300)
        check(view.pointedColor.map { $0 == expected! } ?? false, "放大镜取到鼠标指着那一点的颜色（换算成 sRGB）")
        view.keyDown(with: key("c", code: 8))
        if let e = expected {
            check(picked == ColorText.text(e.0, e.1, e.2, hex: Settings.colorAsHex), "按 C 复制颜色（\(picked ?? "没复制")）")
        }

        // 6. 测量：白底上一块黑（像素 100…299 × 60…179）
        let measureImage = makeMeasureImage()
        let mv = MeasureView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), image: measureImage, backingScale: 2)
        var copied: String?
        mv.onCopy = { copied = $0 }
        mv.measureEdges(at: CGPoint(x: 100, y: 75))
        check(mv.copyText == "100 × 60", "测量：鼠标在黑块里 → 自动量出 100 × 60 点（200 × 120 像素）")
        mv.measureBox(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        check(mv.copyText == "50 × 30", "测量：拖框量出 50 × 30 点")
        mv.keyDown(with: key("c", code: 8))
        check(copied == "50 × 30", "测量：按 C 复制尺寸")

        let pinMenu = PinWindow(image: image, pointSize: NSSize(width: 100, height: 100),
                                frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1).makeContextMenu().items.map(\.title)
        check(pinMenu.contains("识别文字"), "贴图右键菜单里有「识别文字」")
    }

    // MARK: 长截图

    private static func testLongShot(menu: NSMenu?) {
        let titles = menu?.items.map(\.title) ?? []
        check(titles.contains("长截图（框选后往下滚，拼成一张长图）"), "菜单里有\u{201C}长截图\u{201D}")

        // 截图工具栏上的按钮
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: image, viewSize: viewSize))
        var longShots = 0
        editor.onLongShot = { longShots += 1 }
        let button = findButton(in: editor.toolbar) { $0.toolTip?.hasPrefix("长截图") == true }
        button?.performClick(nil)
        check(button != nil && longShots == 1, "截图工具栏有\u{201C}长截图\u{201D}按钮，点了交给长截图")
        editor.tearDown()

        if let screen = NSScreen.main {
            let r = SelectionSession.region(CGRect(x: 100, y: 120, width: 500, height: 600), on: screen)
            check(r.viewRect == CGRect(x: 100, y: 120, width: 500, height: 600) && r.screenFrame == screen.frame
                  && r.displayID == screen.displayID, "选好的框 → 长截图要拍的区域")
        }

        // 假网页：250 像素宽，顶部导航栏 30 行、底部输入框 24 行固定，框里一次露出 300 行
        let w = 250, header = 30, visible = 300, footer = 24
        func contentGray(_ x: Int, _ y: Int) -> UInt8 {
            let line = y / 18, row = y % 18
            guard row < 11, x >= 10, x < w - 10 else { return 255 }
            var h = UInt32(truncatingIfNeeded: line &* 7919 &+ (x / 4) &* 104729 &+ row &* 31)
            h = (h ^ (h >> 13)) &* 1274126177
            return (h >> 7) % 3 == 0 ? 30 : 245
        }
        func headerGray(_ x: Int, _ y: Int) -> UInt8 { y == header - 1 ? 140 : (x % 10 < 5 ? 220 : 110) }
        func footerGray(_ x: Int, _ y: Int) -> UInt8 { y == 0 ? 160 : (x > 20 && x < 150 && y > 6 && y < 18 ? 235 : 205) }
        func pageGray(lastOffset o: Int, _ x: Int, _ y: Int) -> UInt8 {
            if y < header { return headerGray(x, y) }
            if y < header + o + visible { return contentGray(x, y - header) }
            return footerGray(x, y - header - o - visible)
        }
        func frameImage(_ o: Int) -> CGImage? {
            grayImage(width: w, height: header + visible + footer) { x, y in
                y < header ? headerGray(x, y) : y < header + visible ? contentGray(x, o + y - header) : footerGray(x, y - header - visible)
            }
        }

        let capture = LongShotCapture()
        var events: [ScrollStitcher.Event] = []
        var thumbs = 0
        capture.onProgress = { p in
            events.append(p.event)
            if p.thumb != nil { thumbs += 1 }
        }
        let offsets = [0, 0, 25, 60, 61, 140, 100, 230, 320, 410, 500, 590, 680, 770, 860, 950, 1040, 1100]
        var padded = false
        for o in offsets {
            guard let img = frameImage(o), let buffer = pixelBuffer(from: img),
                  let frame = LongShotCapture.frame(from: buffer) else { check(false, "长截图：造假画面"); return }
            if CVPixelBufferGetBytesPerRow(buffer) > w * 4 { padded = true }
            capture.queue.async { capture.process(frame) }
        }
        let stitched = awaitResult { await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            capture.finish { c.resume(returning: $0) }
        } } ?? nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let last = offsets.last ?? 0
        let expectedEvents: [ScrollStitcher.Event] = [.first, .same, .appended(25), .appended(35), .appended(1), .appended(79), .up(40)]
            + (7..<offsets.count).map { .appended(offsets[$0] - offsets[$0 - 1]) }
        if events != expectedEvents { info("长截图收到的：\(events)") }
        check(events == expectedEvents, "长截图：系统给的画面（行尾带填充：\(padded)）一张张拼上，往回滚就退回去")
        check(thumbs == offsets.count - 1, "长截图：每拼上一段、退回一段，预览小图就更新（没变的那张不更新）")
        let expectedHeight = header + last + visible + footer
        var same = stitched?.width == w && stitched?.height == expectedHeight
        if same, let stitched, let px = PixelBuffer(image: stitched) {
            outer: for y in 0..<expectedHeight {
                for x in stride(from: 0, to: w, by: 1) {
                    let g = Int(pageGray(lastOffset: last, x, y))
                    let c = px.rgb(x, y)
                    if c.0 != g || c.1 != g || c.2 != g { same = false; info("长截图第一个不对的像素：(\(x), \(y)) \(c) ≠ \(g)"); break outer }
                }
            }
        }
        check(same, "长截图：拼出来和原网页一模一样（\(w)×\(stitched?.height ?? 0)，导航栏、输入框各一份）")

        // 控制条、预览条（不显示窗口、不拍屏幕、不注册回车和 Esc）
        if let screen = NSScreen.main {
            let region = ScreenRegion(displayID: screen.displayID ?? CGMainDisplayID(), screenFrame: screen.frame,
                                      viewRect: CGRect(x: 300, y: 200, width: 600, height: 500))
            let session = LongShotSession(region: region)
            var finishes: [CGImage?] = []
            session.onFinish = { finishes.append($0) }
            session.begin(startCapture: false, showWindows: false)
            check(LongShotSession.active === session && session.bar.label.stringValue == LongShotControlBar.startText,
                  "长截图开始：控制条提示往下滚、回车完成、Esc 取消")
            check(session.preview.panel.frame == LongShotGeometry.previewFrame(region: region.globalRect, visible: screen.visibleFrame,
                                                                             width: LongShotPreview.width)
                  && session.bar.panel.frame.width > 400, "长截图：预览条在框旁边，控制条放得下进度和按钮")
            session.handle(LongShotProgress(event: .appended(40), totalHeight: 1400, screens: 1.4, thumb: stitched))
            check(session.bar.label.stringValue == "已拼约 1.4 屏　1400 像素高" && !session.bar.isWarning
                  && session.preview.view.image != nil, "长截图：拼上一段 → 进度更新、预览出图")
            session.handle(LongShotProgress(event: .lost, totalHeight: 1400, screens: 1.4, thumb: nil))
            check(session.bar.isWarning && session.bar.label.stringValue.contains("往回滚"), "长截图：对不上 → 黄字提示往回滚一点")
            session.handle(LongShotProgress(event: .appended(30), totalHeight: 1430, screens: 1.43, thumb: nil))
            check(!session.bar.isWarning, "长截图：又对上了 → 提示恢复")
            session.handle(LongShotProgress(event: .full, totalHeight: 30000, screens: 13, thumb: nil))
            check(session.bar.label.stringValue.contains("上限"), "长截图：到上限 → 提示点完成")
            session.cancel()
            check(finishes.count == 1 && finishes[0] == nil && LongShotSession.active == nil, "长截图：取消 → 什么都不留")

            let done = LongShotSession(region: region)
            var doneImage: CGImage?
            done.onFinish = { doneImage = $0 }
            done.begin(startCapture: false, showWindows: false)
            for o in [0, 50] {
                if let img = frameImage(o), let buffer = pixelBuffer(from: img), let f = LongShotCapture.frame(from: buffer) {
                    done.capture.queue.async { done.capture.process(f) }
                }
            }
            done.finish()
            let deadline = Date().addingTimeInterval(5)
            while doneImage == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(doneImage?.height == header + 50 + visible + footer && LongShotSession.active == nil, "长截图：点完成 → 交出拼好的长图")
        }

        let scroller = AutoScroller(region: CGRect(x: 100, y: 200, width: 600, height: 700))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        check(scroller.point == CGPoint(x: 400, y: primaryHeight - 550) && scroller.step == 42 && !scroller.isRunning,
              "自动滚动：在框的正中间滚，每次 42 点（自检里不真滚）")

        // 复制 + 存 PNG（私有剪贴板、临时文件夹）
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.longshot.\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitLongShot-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
            pb.releaseGlobally()
        }
        if let stitched {
            let out = LongShotTool.output(stitched, scale: 2, pasteboard: pb, folder: folder)
            let saved = out?.url.flatMap { NSImage(contentsOf: $0) }
            check(out?.url != nil && saved != nil && pb.data(forType: .png) != nil && pb.data(forType: .tiff) != nil
                  && out?.pointSize == NSSize(width: CGFloat(w) / 2, height: CGFloat(stitched.height) / 2),
                  "长截图：复制到剪贴板，同时存成 PNG（点数 = 像素 ÷ 2）")
        }
        if let big = grayImage(width: 4001, height: 4001, { _, _ in 255 }) {
            _ = LongShotTool.output(big, scale: 2, pasteboard: pb, folder: folder)
            // 只写了 PNG；别的软件要 TIFF 时系统会现转，平时不占几百 MB
            check(pb.data(forType: .png) != nil && pb.types?.first == .png, "长截图：图很大时剪贴板里只写 PNG")
        }
    }

    // MARK: 台阶 9 杂项：系统状态、防休眠、延时截图、排窗口小抄

    private static func testMisc(menu: NSMenu?, recorder: RecorderTool) {
        let items = menu?.items ?? []
        let titles = items.map { $0.attributedTitle?.string ?? $0.title }
        check(titles.first == "系统状态（点一下打开活动监视器）" && titles.count > 3 && titles[1].hasPrefix("CPU") && titles[1].contains("内存")
              && titles[2].hasPrefix("网速") && titles[3].hasPrefix("磁盘"),
              "菜单最上面是系统状态：CPU 和内存、网速、磁盘（点一下打开活动监视器）")
        check(titles.contains("延时截图") && titles.contains("防休眠：关") && titles.contains("排窗口（系统自带的快捷键）"),
              "菜单里有延时截图、防休眠、排窗口小抄")
        let delaySub = items.first { $0.title == "延时截图" }?.submenu?.items.map(\.title) ?? []
        check(delaySub.starts(with: ["3 秒后截图", "5 秒后截图", "10 秒后截图"]), "延时截图：3 / 5 / 10 秒")
        let tips = items.first { $0.title == "排窗口（系统自带的快捷键）" }?.submenu?.items.map(\.title) ?? []
        check(tips == WindowTipsTool.lines, "排窗口小抄：拖到边缘、地球键快捷键都写上了")

        // 系统状态：真的读一次（只读）
        check(SystemStats.cpuTicks() != nil, "能读到 CPU 计数")
        let used = SystemStats.memoryUsed() ?? 0
        check(used > 0 && used < SystemStats.memoryTotal, "已使用内存在 0 和总内存之间（\(SystemText.size(Double(used), decimal: false))）")
        check((SystemStats.diskAvailable() ?? 0) > 0, "能读到磁盘剩余空间")
        info("网卡：\(SystemStats.networkCounters().keys.sorted().joined(separator: "、"))；电池：\(SystemStats.battery().map { "\($0.percent)%" } ?? "没有")")
        let status = SystemStatusTool()
        _ = status.menuItems()
        // 系统的 CPU 计数不是时时刻刻在变，隔太短可能还没动：最多等 3 秒
        let statusDeadline = Date().addingTimeInterval(3)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            status.tick()
        } while status.cpu == nil && Date() < statusDeadline
        let lines = status.lines
        check(status.cpu.map { (0...1).contains($0) } == true && (status.down ?? -1) >= 0 && (status.up ?? -1) >= 0,
              "隔一会儿再取一次 → 算出 CPU 使用率和网速")
        check(lines.count == 3 && lines[0].contains("%") && lines[0].contains("已用") && lines[1].contains("↓")
              && lines[2].contains("剩余"), "系统状态三行都有数：\(lines.joined(separator: " | "))")

        // 防休眠（只走逻辑，不真的去挡系统休眠）
        let awake = KeepAwakeTool()
        awake.dryRun = true
        var cups: [Bool] = []
        awake.onChange = { cups.append($0) }
        awake.turnOn(minutes: 30)
        check(awake.isOn && awake.holding && awake.statusTitle == "防休眠中，还剩 30 分钟" && cups.last == true && awake.assertionID == nil,
              "防休眠 30 分钟：菜单写着还剩 30 分钟，图标换成咖啡杯")
        let sub = awake.menuItems().first?.submenu?.items.map(\.title) ?? []
        check(awake.menuItems().first?.state == .on && sub.starts(with: ["30 分钟", "1 小时", "2 小时", "一直开着"]) && sub.contains("关掉"),
              "防休眠菜单：30 分钟 / 1 小时 / 2 小时 / 一直开着 / 关掉")
        awake.turnOff()
        check(!awake.isOn && !awake.holding && awake.statusTitle == "防休眠：关" && cups.last == false, "关掉防休眠 → 图标变回扳手")
        awake.turnOn(minutes: nil)
        check(awake.statusTitle == "防休眠中（一直开着）", "防休眠一直开着")
        awake.turnOff()
        awake.setRecording(true)
        check(awake.holding && awake.statusTitle == "录屏中，自动防休眠" && cups.last == false, "录屏时自动防休眠（图标还是录屏的红点）")
        awake.turnOn(until: Date().addingTimeInterval(0.2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(!awake.manualOn && awake.holding, "时间到自动关掉手动的防休眠；录屏还在 → 继续挡着")
        awake.setRecording(false)
        check(!awake.holding && !awake.isOn, "录完恢复原样")
        check(!recorder.isBusy, "录屏没在忙时不防休眠")

        // 延时截图的倒数（不显示窗口、不注册 Esc，倒数调快）
        let countdown = DelayCountdown(seconds: 3, center: .zero, showWindow: false, interval: 0.05)
        var fired = 0, cancelled = 0
        countdown.onFire = { fired += 1 }
        countdown.onCancel = { cancelled += 1 }
        countdown.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(fired == 1 && cancelled == 0 && countdown.remaining == 0 && !countdown.isRunning, "延时截图：倒数 3、2、1 后开始截图")
        let stopped = DelayCountdown(seconds: 3, center: .zero, showWindow: false, interval: 0.05)
        var stoppedFired = 0, stoppedCancelled = 0
        stopped.onFire = { stoppedFired += 1 }
        stopped.onCancel = { stoppedCancelled += 1 }
        stopped.start()
        stopped.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(stoppedFired == 0 && stoppedCancelled == 1, "延时截图：倒数时按 Esc → 取消，不截")
        check(CountdownWindow(center: .zero, hint: "Esc 取消").panel.contentView?.subviews.count == 2, "倒数的数字下面写着\u{201C}Esc 取消\u{201D}")
    }

    // MARK: 台阶 10 统一样子

    /// 菜单里所有的字（连子菜单）
    private static func allTitles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            [item.attributedTitle?.string ?? item.title] + (item.submenu.map(allTitles) ?? [])
        }
    }

    private static func testMenuLayout(_ menu: NSMenu?) {
        guard let menu else { check(false, "菜单存在"); return }
        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        check(headers == ["系统状态（点一下打开活动监视器）", "截图", "录屏", "剪贴板", "识别", "小工具"],
              "菜单分组有小标题：\(headers.joined(separator: "、"))")
        let rows = menu.items.filter { !$0.isSeparatorItem }
        check(rows.count <= 30, "菜单第一层 \(rows.count) 行（整理前 40 多行）")
        func sub(_ title: String) -> [String] { menu.items.first { $0.title == title }?.submenu.map(allTitles) ?? [] }
        let shot = sub("截图设置")
        check(shot.contains { $0.hasPrefix("截图快捷键") } && shot.contains("截图保存位置") && shot.contains { $0.hasPrefix("贴图快捷键") }
              && shot.contains { $0.hasPrefix("快速模式") } && shot.contains { $0.hasPrefix("截图时按 C") }, "截图设置里有截图、贴图的快捷键和保存位置")
        check(sub("录屏设置").contains { $0.hasPrefix("画质") } && sub("剪贴板设置").contains { $0.hasPrefix("剪贴板快捷键") }
              && sub("剪贴板设置").contains("暂停记录") && sub("识别设置").contains { $0.hasPrefix("识别文字快捷键") }
              && sub("识别设置").contains { $0.hasPrefix("测量快捷键") }, "录屏、剪贴板、识别的设置都收进各自的\u{201C}设置\u{201D}子菜单")
        let everything = allTitles(menu)
        let mustHave = ["截取整个屏幕", "长截图（框选后往下滚，拼成一张长图）", "延时截图", "3 秒后截图", "贴图（剪贴板里的图片或文字）",
                        "录屏（框选 / 单击窗口 / 整屏）", "识别文字（框选）", "测量（自动量宽高、拖框量大小）", "排窗口（系统自带的快捷键）",
                        "30 分钟", "截图保存位置", "录完自动打开预览", "关于 MacKit", "退出 MacKit"]
        let missing = mustHave.filter { !everything.contains($0) }
        check(missing.isEmpty && everything.contains { $0.hasPrefix("剪贴板历史（") } && everything.contains { $0.hasPrefix("MacKit ") }
              && everything.contains { $0.hasPrefix("屏幕录制权限") },
              "整理后每个功能都还在\(missing.isEmpty ? "" : "（少了：\(missing.joined(separator: "、"))）")")
    }

    private static func testIconAndWindows() {
        check(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon"
              && Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil, "App 里有图标（AppIcon.icns）")
        if let icon = IconMaker.draw(size: 128) {
            let corner = pixelAlpha(icon, x: 2, y: 2), edge = pixel(icon, x: 20, y: 64)
            var blue = 0
            if let px = PixelBuffer(image: icon) {
                for y in 30..<98 { for x in 30..<98 { let c = px.rgb(x, y); if c.2 > c.0 + 80 && c.2 > 180 { blue += 1 } } }
            }
            check(icon.width == 128 && corner == 0 && blue > 400 && edge.r < 80 && edge.g < 80,
                  "图标：四角透明、中间是蓝色的扳手和螺丝刀（\(blue) 个蓝点）、底是深色")
        } else {
            check(false, "图标画得出来")
        }
        let row = ClipboardSelectionRowView()
        check(row.isEmphasized, "剪贴板小窗口：选中行按强调样式画（主题色底、白字）")
    }

    /// 读一个像素的透明度，y 从上往下数
    private static func pixelAlpha(_ image: CGImage, x: Int, y: Int) -> Int {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return Int(bytes[3])
    }

    // MARK: 1.0 上线：第一次打开、两套快捷键、欢迎窗口

    private static func testRelease(_ menu: NSMenu?) {
        check(FirstLaunch.decide(done: false, hasPreviousData: true) == .keepOldHotKeys
              && FirstLaunch.decide(done: false, hasPreviousData: false) == .welcome
              && FirstLaunch.decide(done: true, hasPreviousData: false) == .nothing
              && FirstLaunch.decide(done: true, hasPreviousData: true) == .nothing,
              "第一次打开 1.0：老用户快捷键原样留着，新用户弹欢迎窗口，办过一次就不再管")
        let control = HotKeyScheme.control.indices, command = HotKeyScheme.command.indices
        let controlKeys = [HotKeyPresets.screenshot[control[0]].display, PinHotKeyPresets.all[control[1]].pin.display,
                           ClipboardHotKeyPresets.all[control[2]].display, RecordHotKeyPresets.all[control[3]].display,
                           RecognizeHotKeyPresets.ocr[control[4]].display, RecognizeHotKeyPresets.measure[control[5]].display]
        let commandKeys = [HotKeyPresets.screenshot[command[0]].display, PinHotKeyPresets.all[command[1]].pin.display,
                           ClipboardHotKeyPresets.all[command[2]].display, RecordHotKeyPresets.all[command[3]].display,
                           RecognizeHotKeyPresets.ocr[command[4]].display, RecognizeHotKeyPresets.measure[command[5]].display]
        check(controlKeys == ["⌃⇧1", "⌃⇧2", "⌃⇧3", "⌃⇧4", "⌃⇧5", "⌃⇧6"] && commandKeys == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6"]
              && PinHotKeyPresets.all[control[1]].toggle.display == "⌃⌥⇧2",
              "两套快捷键：⌃⇧1–⌃⇧6（贴图隐藏是 ⌃⌥⇧2）和 ⌘1–⌘6；新的加在最后，老用户存的\u{201C}第几个\u{201D}不会错位")
        check(HotKeyPresets.screenshot[0].display == "⌘1" && !HotKeyPresets.screenshot[0].note.contains("你的"),
              "老用户的第一个选项还是 ⌘1，说明文字不再写\u{201C}你的 Snipaste\u{201D}")

        // 欢迎窗口（不显示）：选一套 → 六个快捷键一起换；测完换回原样
        let saved = [Settings.screenshotHotKeyIndex, Settings.pinHotKeyIndex, Settings.clipboardHotKeyIndex,
                     Settings.recordHotKeyIndex, Settings.ocrHotKeyIndex, Settings.measureHotKeyIndex]
        defer {
            Settings.screenshotHotKeyIndex = saved[0]; Settings.pinHotKeyIndex = saved[1]; Settings.clipboardHotKeyIndex = saved[2]
            Settings.recordHotKeyIndex = saved[3]; Settings.ocrHotKeyIndex = saved[4]; Settings.measureHotKeyIndex = saved[5]
        }
        let welcome = WelcomeWindow()
        var changed: [HotKeyScheme] = []
        welcome.onSchemeChange = { changed.append($0) }
        check(welcome.schemeButtons.count == 2 && welcome.permissionRows.keys.sorted() == ["accessibility", "media", "screen"]
              && welcome.permissionRows["screen"]?.button != nil && welcome.permissionRows["media"]?.button == nil,
              "欢迎窗口：屏幕录制、辅助功能各有\u{201C}去打开\u{201D}，麦克风摄像头只是说明；两套快捷键可选")
        welcome.choose(.control)
        check(Settings.hotKeyScheme == .control && Settings.screenshotHotKey.display == "⌃⇧1" && changed == [.control]
              && welcome.schemeButtons[.control]?.state == .on, "欢迎窗口里选 ⌃⇧ 那套：六个快捷键一起换，各积木重新注册")
        welcome.choose(.command)
        check(Settings.hotKeyScheme == .command && Settings.measureHotKeyIndex == 0, "再换回 ⌘ 那套")
        Settings.clipboardHotKeyIndex = 1
        check(Settings.hotKeyScheme == nil, "单独改过某一个快捷键：哪套都不算，欢迎窗口里两个都不选")
        welcome.window.close()

        // 关于菜单
        let aboutTitles = menu?.items.first { $0.title == "关于 MacKit" }?.submenu?.items.map(\.title) ?? []
        check(aboutTitles.contains("使用说明（权限、快捷键）…") && aboutTitles.contains("打开项目主页") && aboutTitles.contains("看看有没有新版本")
              && AppLinks.home.absoluteString == "https://github.com/itzzan/MacKit" && AppLinks.releases.path == "/itzzan/MacKit/releases",
              "关于 MacKit：使用说明、项目主页、看看有没有新版本")
        let parts = AppInfo.version.split(separator: ".").compactMap { Int($0) }
        check(parts.count == 3 && parts[0] >= 1, "版本号是三段数字、1 以上：\(AppInfo.version)")
    }

    private static func testTheme() {
        // 按钮：几种样子的底色
        let plain = ToolbarButton(symbol: "rectangle", tip: "") {}
        check(plain.fillColor == nil, "普通按钮：透明底")
        plain.isHoveredLook = true
        check(plain.fillColor == Theme.hoverFill, "鼠标放上去：亮一下")
        plain.isPressedLook = true
        check(plain.fillColor == Theme.pressedFill, "按下去：再亮一点")
        plain.isPressedLook = false
        plain.isHoveredLook = false
        plain.isSelectedLook = true
        check(plain.fillColor == Theme.accent, "选中的工具：主题色底")
        let primary = ToolbarButton(symbol: "checkmark", tip: "", style: .primary) {}
        let danger = ToolbarButton(symbol: "stop.fill", title: "停止", tip: "", style: .danger) {}
        check(primary.fillColor == Theme.accent && danger.fillColor == Theme.record, "主按钮是主题色、停止是红色")
        let titled = ToolbarButton(symbol: "play.fill", title: "现在开始", tip: "") {}
        func fixed(_ b: NSButton, _ attribute: NSLayoutConstraint.Attribute) -> CGFloat? {
            b.constraints.first { $0.firstAttribute == attribute && $0.secondItem == nil && $0.isActive }?.constant
        }
        check((fixed(titled, .width) ?? 0) > 80 && fixed(plain, .width) == Theme.buttonSize
              && fixed(titled, .height) == Theme.buttonSize && fixed(plain, .height) == Theme.buttonSize,
              "带字的按钮按字的长短定宽，所有按钮一样高（\(Int(Theme.buttonSize)) 点）")

        // 浮动条都用统一底板：圆角、细边框
        func usesTheme(_ view: NSView?, radius: CGFloat = Theme.barRadius) -> Bool {
            guard let layer = view?.layer else { return false }
            return layer.cornerRadius == radius && layer.borderWidth == 1 && layer.masksToBounds
        }
        let toolbar = AnnotationToolbar(mode: .screenshot)
        check(usesTheme(toolbar.subviews.first), "截图工具栏用统一底板")
        check(usesTheme(RecordingControlBar(systemAudio: true, microphone: false).panel.contentView), "录屏控制条用统一底板")
        check(usesTheme(LongShotControlBar().panel.contentView), "长截图控制条用统一底板")
        check(usesTheme(KeyCastWindow().panel.contentView, radius: 12), "按键牌子用统一底板")
        check(usesTheme(CountdownWindow(center: .zero).panel.contentView, radius: 70), "倒数用统一底板（圆的）")
        check(usesTheme(Toast.makePanel("✓ 好了").contentView?.subviews.first)
              && usesTheme(Toast.makeActionsPanel("好了", actions: [("打开", {})]).contentView), "提示条、带按钮的提示条用统一底板")

        // 录制小条
        let hud = RecordingHUD(systemAudio: true, microphone: false)
        check(hud.isPulsing && usesTheme(hud.panel.contentView) && hud.buttons["stop"]?.style == .danger
              && hud.buttons["pause"]?.style == .plain, "录制小条：红点在呼吸，停止是红色按钮")
        hud.setMode(.paused)
        let pausedTexts = (hud.panel.contentView?.subviews.first as? NSStackView)?.arrangedSubviews
            .compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        check(!hud.isPulsing && pausedTexts.contains("已暂停") && hud.buttons["resume"]?.style == .primary,
              "暂停时红点不闪、写着\u{201C}已暂停\u{201D}，继续是主按钮")

        // 提示条：看文字配图标
        check(Toast.kind(of: "✓ 已复制到剪贴板") == (.success, "已复制到剪贴板") && Toast.kind(of: "截图失败：图片编码出错").0 == .failure
              && Toast.kind(of: "长截图失败：…").0 == .failure && Toast.kind(of: "已取消延时截图").0 == .info,
              "提示条：✓ 开头配绿勾，失败配黄色感叹号，别的不配图标")
        let successRow = Toast.content("✓ 好了")
        check(successRow.count == 2 && (successRow.first as? NSImageView)?.contentTintColor == Theme.success
              && (successRow.last as? NSTextField)?.stringValue == "好了", "成功提示：绿勾 + 去掉 ✓ 的文字")

        // 颜色各归各位
        let longShotBorder = RecordingBorderWindow(region: CGRect(x: 100, y: 100, width: 300, height: 200),
                                                   screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                                   adjustable: false, color: Theme.accent)
        let recordBorder = RecordingBorderWindow(region: CGRect(x: 100, y: 100, width: 300, height: 200),
                                                 screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        check((longShotBorder.panel.contentView as? RecordingBorderView)?.color == Theme.accent
              && (recordBorder.panel.contentView as? RecordingBorderView)?.color == Theme.record,
              "长截图的框是主题色，录屏的框是红色")
    }

    private static func findButton(in view: NSView, where match: (NSButton) -> Bool) -> NSButton? {
        if let b = view as? NSButton, match(b) { return b }
        for sub in view.subviews { if let found = findButton(in: sub, where: match) { return found } }
        return nil
    }

    /// 灰度假图（sRGB）：gray(x, y)，y 从上往下数
    private static func grayImage(width: Int, height: Int, _ gray: (Int, Int) -> UInt8) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = gray(x, y), i = (y * width + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 像系统送来的画面一样：BGRA 的 CVPixelBuffer
    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func makeQRCode(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output.composited(over: CIImage(color: .white).cropped(to: output.extent)), from: output.extent)
    }

    private static func makeMeasureImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 300 - 180, width: 200, height: 120))      // 像素 y 60…179（左上原点）
        return ctx.makeImage()!
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
                                                                            quality: .original60, showClicks: true), excluding: [])
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


/// 长截图实录检查：MacKit --longshot-smoke <结果文件>
/// 真的拍屏幕左上角一小块 1.5 秒（不弹窗口、不滚动、不存文件），看系统画面能不能送到、拼出来尺寸对不对；
/// 再用 1600×1600 的大假画面量一下拼一张要多久（每秒 8 张，得跟得上）。要用 open 启动
@MainActor
enum LongShotSmokeTest {
    static func run(resultPath: String) {
        Task { @MainActor in
            var lines: [String] = []
            var ok = true
            guard let screen = NSScreen.screens.first, let id = screen.displayID else { finish(["没有屏幕"], false, resultPath); return }
            let scale = screen.backingScaleFactor
            let region = ScreenRegion(displayID: id, screenFrame: screen.frame,
                                      viewRect: CGRect(x: 40, y: screen.frame.height - 60 - 200, width: 300, height: 200))
            let capture = LongShotCapture()
            var events: [ScrollStitcher.Event] = []
            capture.onProgress = { events.append($0.event) }
            do {
                try await capture.start(region: region)
                try? await Task.sleep(for: .seconds(1.5))
                let image: CGImage? = await withCheckedContinuation { c in capture.finish { c.resume(returning: $0) } }
                let expect = (Int(300 * scale), Int(200 * scale))
                lines.append("实拍：收到 \(events.count) 张（第一张：\(events.first.map { "\($0)" } ?? "无")），"
                             + "拼出 \(image?.width ?? 0)×\(image?.height ?? 0)，应为 \(expect.0)×\(expect.1)")
                ok = ok && events.first == .first && image?.width == expect.0 && image?.height == expect.1
            } catch {
                lines.append("实拍失败：\(error.localizedDescription)")
                ok = false
            }

            // 速度：1600 宽、一屏 1600 行，每次滚 120 行
            let w = 1600, h = 1600, total = h + 120 * 12
            var page = [UInt8](repeating: 255, count: w * total * 4)
            for y in 0..<total where y % 28 < 16 {
                for x in 20..<(w - 20) {
                    var v = UInt32(truncatingIfNeeded: (y / 28) &* 7919 &+ (x / 6) &* 104729 &+ (y % 28) &* 31)
                    v = (v ^ (v >> 13)) &* 1274126177
                    if (v >> 7) % 3 == 0 { let i = (y * w + x) * 4; page[i] = 30; page[i + 1] = 30; page[i + 2] = 30 }
                }
            }
            let stitcher = ScrollStitcher()
            var appended = 0
            let start = Date()
            for k in 0...12 {
                let o = k * 120
                let frame = StitchFrame(width: w, height: h, pixels: Array(page[(o * w * 4)..<((o + h) * w * 4)]))
                if case .appended = stitcher.add(frame) { appended += 1 }
            }
            let ms = Date().timeIntervalSince(start) * 1000 / 13
            lines.append(String(format: "速度：1600×1600 的画面拼一张平均 %.0f 毫秒（每秒 8 张要在 125 毫秒内），接上 %d/12 段", ms, appended))
            ok = ok && ms < 125 && appended == 12 && stitcher.result()?.height == total
            finish(lines, ok, resultPath)
        }
    }

    private static func finish(_ lines: [String], _ ok: Bool, _ path: String) {
        try? (lines + [ok ? "SMOKE OK" : "SMOKE FAILED"]).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }
}
