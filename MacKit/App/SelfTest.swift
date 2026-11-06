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
                    emergencyQuit: Bool, settingsHooks: SettingsHooks) {
        check(statusItem.button?.image != nil, "菜单栏图标已创建")
        check(emergencyQuit, "紧急退出快捷键 \(EmergencyHotKey.quit.display) 已注册")
        info("截图快捷键 \(Settings.screenshotHotKey?.display ?? "没设") 注册\(screenshot.hotKeyRegistered ? "成功" : "失败")")
        if let rival = Settings.screenshotHotKey?.runningRival { info("\(rival) 正开着，也在用这个快捷键") }
        info("贴图快捷键 \(Settings.pinHotKey?.display ?? "没设") / \(Settings.pinToggleHotKey?.display ?? "没设") 注册\(pin.hotKeysRegistered ? "成功" : "失败")")
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
        testMultiSelect()
        testGroupDragFixes()
        testScreenshotPlus()
        testBeautify()
        testPinTransforms()
        testTextEditing()
        testPinAnnotation()
        testClipboard()
        testClipboardPlus()
        testRecorder(recorder)
        testRecordingExtras(recorder)
        testRecordingOverlays(recorder)
        testRecognize()
        testTranslateAndColors()
        testScreenPen(recorder: recorder)
        testAutoZoom()
        testLongShot(menu: statusItem.menu)
        testMisc(menu: statusItem.menu, recorder: recorder)
        testTheme()
        testMenuLayout(statusItem.menu)
        testIconAndWindows()
        testRelease(statusItem.menu)
        testSettingsWindow(hooks: settingsHooks, menu: statusItem.menu)

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
        check(!editor.canAdjustSelection && editor.canResizeSelection, "画了第一笔：框不能整个挪了，但边和角还能拖（台阶 20）")

        view.keyDown(with: key("r", code: 15))
        check(editor.tool == nil, "再按一次 R 放下工具")
        view.mouseDown(with: mouse(.leftMouseDown, fixed.maxX, fixed.minY))
        view.mouseDragged(with: mouse(.leftMouseDragged, fixed.maxX + 100, fixed.minY - 50))
        view.mouseUp(with: mouse(.leftMouseUp, fixed.maxX + 100, fixed.minY - 50))
        check(view.currentSelection == CGRect(x: fixed.minX, y: fixed.minY - 50, width: fixed.width + 100, height: fixed.height + 50),
              "画了以后拖右下角的小方块：框跟着变大（台阶 20 起；以前是锁死的）")
        view.mouseDown(with: mouse(.leftMouseDown, fixed.maxX + 100, fixed.minY - 50))
        view.mouseDragged(with: mouse(.leftMouseDragged, fixed.maxX, fixed.minY))
        view.mouseUp(with: mouse(.leftMouseUp, fixed.maxX, fixed.minY))
        check(view.currentSelection == fixed, "再拖回去：框回到原样")

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
    // MARK: 台阶 19 一次选好几个、复制、上下层

    private static func testMultiSelect() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: image, viewSize: viewSize))
        defer { editor.tearDown() }
        var cancelled = 0, done = 0
        view.onCancel = { cancelled += 1 }
        view.onDone = { done += 1 }
        view.beginEditing(editor, selection: CGRect(x: 100, y: 100, width: 800, height: 600))
        editor.setColor(.red)
        editor.setSize(.medium)
        func click(_ x: CGFloat, _ y: CGFloat, _ mods: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouse(.leftMouseDown, x, y, mods: mods))
            view.mouseUp(with: mouse(.leftMouseUp, x, y, mods: mods))
        }
        func drag(_ from: CGPoint, _ to: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouse(.leftMouseDown, from.x, from.y, mods: mods))
            view.mouseDragged(with: mouse(.leftMouseDragged, (from.x + to.x) / 2, (from.y + to.y) / 2, mods: mods))
            view.mouseDragged(with: mouse(.leftMouseDragged, to.x, to.y, mods: mods))
            view.mouseUp(with: mouse(.leftMouseUp, to.x, to.y, mods: mods))
        }
        func command(_ chars: String, _ code: UInt16) -> Bool { view.performKeyEquivalent(with: key(chars, code: code, mods: .command)) }
        var items: [Annotation] { editor.document.items }

        // ①②③
        view.keyDown(with: key("n", code: 45))
        for x in [200, 260, 320] as [CGFloat] { click(x, 200) }
        editor.selectTool(nil)
        check(items.map(\.number) == [1, 2, 3], "准备：画了 ①②③")

        // ⇧ 在空白处拖框选
        view.mouseDown(with: mouse(.leftMouseDown, 150, 150, mods: .shift))
        view.mouseDragged(with: mouse(.leftMouseDragged, 300, 230, mods: .shift))
        check(editor.isBandSelecting && editor.canvas.bandRect != nil && editor.selectedIndices == IndexSet([0, 1]),
              "按住 ⇧ 在空白处拖：拖的时候画出框，框到的跟着选上")
        view.mouseDragged(with: mouse(.leftMouseDragged, 350, 250, mods: .shift))
        view.mouseUp(with: mouse(.leftMouseUp, 350, 250, mods: .shift))
        check(editor.selectedIndices == IndexSet(0...2) && editor.canvas.bandRect == nil && editor.canvas.groupFrames.count == 3
              && editor.canvas.selectionLook == nil && items.count == 3,
              "松手：三个都选上，每个一圈虚线框、没有改大小的小方块；没画出新东西")

        // 一起拖、只算一步撤销
        drag(CGPoint(x: 260, y: 200), CGPoint(x: 260, y: 300))
        check(items.allSatisfy { $0.points[0].y == 300 } && editor.selectedIndices.count == 3, "点住其中一个拖：三个一起挪")
        editor.undo()
        check(items.allSatisfy { $0.points[0].y == 200 }, "一起拖一次 = 撤销一步，三个都回去")

        // ⌘A、一起删
        check(command("a", 0) && editor.selectedIndices == IndexSet(0...2), "⌘A：全选")
        view.keyDown(with: key("\u{7f}", code: 51))
        check(items.isEmpty, "⌫：一起删掉")
        editor.undo()
        check(items.count == 3, "一起删一次 = 撤销一步，三个都回来")

        // ⇧ 点加选、去掉，一起换颜色
        view.keyDown(with: key("r", code: 15))
        drag(CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 500))
        view.keyDown(with: key("a", code: 0))
        drag(CGPoint(x: 420, y: 450), CGPoint(x: 580, y: 450))
        editor.selectTool(nil)
        check(items.count == 5 && items[3].tool == .rect && items[4].tool == .arrow, "准备：再画一个框、框里一个箭头")
        click(400, 450)
        click(500, 450, .shift)
        check(editor.selectedIndices == IndexSet([3, 4]) && editor.selectedIndex == nil, "点框、再 ⇧ 点箭头：两个都选上")
        editor.setColor(.blue)
        check(items[3].color == .blue && items[4].color == .blue && items[0].color == .red, "点蓝色：选上的两个都变蓝，别的不动")
        editor.undo()
        check(items[3].color == .red && items[4].color == .red, "一起换颜色 = 撤销一步")
        editor.redo()
        click(400, 450)
        click(500, 450, .shift)
        click(500, 450, .shift)
        check(editor.selectedIndices == IndexSet([3]), "再 ⇧ 点一下箭头：箭头去掉，只剩框")
        click(500, 450, .shift)
        click(500, 450)
        check(editor.selectedIndices == IndexSet([4]), "选着一组时只点其中一个（不拖）：改成只选它")

        // ⌘D 复制
        let arrow = items[4]
        check(command("d", 2) && items.count == 6 && editor.selectedIndices == IndexSet([5])
              && items[5] == arrow.moved(by: CGVector(dx: 10, dy: -10)) && items[4] == arrow,
              "⌘D：复制一份，往右下错开一点，新的那份选中")
        editor.undo()
        check(items.count == 5, "复制一次 = 撤销一步")
        click(260, 200)
        _ = command("d", 2)
        check(items.count == 6 && items[5].tool == .number && items[5].number == 4, "复制 ②：多出 ④（序号接着编）")
        editor.undo()

        // ⌥ 拖复制
        let rect = items[3]
        drag(CGPoint(x: 400, y: 450), CGPoint(x: 400, y: 350), .option)
        check(items.count == 6 && items[3] == rect && items[5] == rect.moved(by: CGVector(dx: 0, dy: -100))
              && editor.selectedIndices == IndexSet([5]), "按住 ⌥ 拖框：原来的不动，拖出来一个新的")
        editor.undo()
        check(items.count == 5 && items[3] == rect, "⌥ 拖一次 = 撤销一步")

        // 上下层
        click(400, 450)
        check(editor.toolbar.isShowingArrange, "选中东西：工具栏那排多\u{201C}放到最上\u{201D}\u{201C}放到最下\u{201D}")
        check(command("]", 30) && items[4].tool == .rect && items[3].tool == .arrow && editor.selectedIndex == 4, "⌘]：框放到最上")
        check(command("[", 33) && items[0].tool == .rect && editor.selectedIndex == 0, "⌘[：框放到最下")
        editor.undo()
        check(items[4].tool == .rect, "换一次层 = 撤销一步")
        editor.redo()
        click(200, 200)
        click(320, 200, .shift)
        editor.toolbar.onFront?()
        check(items.map { $0.tool == .number ? "\($0.number)" : $0.tool == .rect ? "框" : "箭头" } == ["框", "2", "箭头", "1", "3"]
              && editor.selectedIndices == IndexSet([3, 4]), "①③一起点\u{201C}放到最上\u{201D}：它俩到最上，先后不变（① 还在 ③ 下面）")
        view.keyDown(with: key("\u{1b}", code: 53))
        check(!editor.hasSelection && cancelled == 0 && !editor.toolbar.isShowingArrange, "选着一组时 Esc：只取消选中，不取消截图")
        check(command("d", 2) && items.count == 5, "什么都没选时 ⌘D：什么都不做")
        check(command("c", 8) && done == 1, "⌘C 照旧是复制整张截图并完成")

        // 贴图标注、屏幕画笔（同一套按键，用屏幕画笔测）
        let pen = ScreenPenSession(region: CGRect(x: 100, y: 100, width: 400, height: 300), present: false)
        defer { pen.close() }
        pen.begin(takeKeyboard: false)
        for y in [80, 160] as [CGFloat] {
            pen.input.mouseDown(with: mouse(.leftMouseDown, 50, y))
            pen.input.mouseDragged(with: mouse(.leftMouseDragged, 120, y + 10))
            pen.input.mouseUp(with: mouse(.leftMouseUp, 200, y + 20))
        }
        pen.input.mouseDown(with: mouse(.leftMouseDown, 10, 10, mods: .shift))
        pen.input.mouseDragged(with: mouse(.leftMouseDragged, 300, 250, mods: .shift))
        pen.input.mouseUp(with: mouse(.leftMouseUp, 300, 250, mods: .shift))
        check(pen.editor.document.items.count == 2 && pen.editor.selectedIndices == IndexSet([0, 1]),
              "屏幕画笔（贴图标注同一套）：⇧ 拖框选住两笔，没画出新的")
        _ = pen.input.performKeyEquivalent(with: key("d", code: 2, mods: .command))
        check(pen.editor.document.items.count == 4 && pen.editor.selectedIndices == IndexSet([2, 3]), "屏幕画笔里 ⌘D：两笔一起复制")
        let before = pen.editor.document.items.map(\.points)
        pen.input.mouseDown(with: mouse(.leftMouseDown, 80, 150))
        pen.input.mouseDragged(with: mouse(.leftMouseDragged, 80, 170))
        pen.input.mouseUp(with: mouse(.leftMouseUp, 80, 170))
        check(pen.editor.document.items.count == 4 && pen.editor.document.items[2].points.first?.y == (before[2].first?.y ?? 0) + 20
              && pen.editor.document.items[0].points == before[0],
              "屏幕画笔里选着两笔时，按在它们的虚线框里（不在线上）拖：两笔一起挪，不会画出新的一笔")
        pen.input.keyDown(with: key("\u{7f}", code: 51))
        check(pen.editor.document.items.count == 2, "屏幕画笔里 ⌫：复制出来的两笔一起删掉")
        check(pen.editor.toolbar.arrangeButtons.count == 2, "屏幕画笔的小工具也有\u{201C}放到最上 / 最下\u{201D}")
    }

    /// 2026-11-06 验收：拖不动——按着 ⇧ 拖一组、按在选上的框中间拖，都要能挪
    private static func testGroupDragFixes() {
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        let editor = AnnotationEditor(container: container, mosaic: MosaicSource(image: image, viewSize: viewSize))
        defer { editor.tearDown() }
        view.beginEditing(editor, selection: CGRect(x: 100, y: 100, width: 800, height: 600))
        editor.setColor(.red)
        editor.setSize(.medium)
        func drag(_ from: CGPoint, _ to: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouse(.leftMouseDown, from.x, from.y, mods: mods))
            view.mouseDragged(with: mouse(.leftMouseDragged, (from.x + to.x) / 2, (from.y + to.y) / 2, mods: mods))
            view.mouseDragged(with: mouse(.leftMouseDragged, to.x, to.y, mods: mods))
            view.mouseUp(with: mouse(.leftMouseUp, to.x, to.y, mods: mods))
        }
        func click(_ x: CGFloat, _ y: CGFloat, _ mods: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouse(.leftMouseDown, x, y, mods: mods))
            view.mouseUp(with: mouse(.leftMouseUp, x, y, mods: mods))
        }
        var boxes: [CGRect] { editor.document.items.map(\.box) }
        let a = CGRect(x: 200, y: 200, width: 100, height: 100), b = CGRect(x: 400, y: 200, width: 100, height: 100)

        view.keyDown(with: key("r", code: 15))
        drag(CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 300))
        drag(CGPoint(x: 400, y: 200), CGPoint(x: 500, y: 300))
        editor.selectTool(nil)
        drag(CGPoint(x: 150, y: 150), CGPoint(x: 550, y: 350), .shift)
        check(boxes == [a, b] && editor.selectedIndices == IndexSet([0, 1]), "准备：两个框，⇧ 框选住")

        drag(CGPoint(x: 200, y: 250), CGPoint(x: 200, y: 150), .shift)
        check(boxes == [a.offsetBy(dx: 0, dy: -100), b.offsetBy(dx: 0, dy: -100)] && editor.selectedIndices == IndexSet([0, 1]),
              "框选完还按着 ⇧ 拖：两个一起挪（以前拖不动）")
        editor.undo()
        drag(CGPoint(x: 400, y: 250), CGPoint(x: 400, y: 150), .shift)
        check(boxes == [a, b.offsetBy(dx: 0, dy: -100)] && editor.selectedIndices == IndexSet([1]),
              "撤销后（没选着）⇧ 按住一个拖：先选上它，再挪它")
        editor.undo()
        drag(CGPoint(x: 150, y: 150), CGPoint(x: 550, y: 350), .shift)
        check(editor.editCursor(at: CGPoint(x: 250, y: 250)) == .openHand, "选着一组时，鼠标在框中间变成张开的手：能抓住")
        drag(CGPoint(x: 250, y: 250), CGPoint(x: 250, y: 330))
        check(boxes == [a.offsetBy(dx: 0, dy: 80), b.offsetBy(dx: 0, dy: 80)], "选着一组时按在框中间（不在线上）拖：一起挪（以前拖不动）")
        click(450, 330, .shift)
        check(editor.selectedIndices == IndexSet([0]), "⇧ 点一下（不拖）已经选上的：还是把它去掉")

        editor.undo()
        click(200, 250)
        drag(CGPoint(x: 250, y: 250), CGPoint(x: 280, y: 250))
        check(boxes == [a.offsetBy(dx: 30, dy: 0), b], "没拿工具、只选着一个框：按在框中间拖也能挪它")
        editor.undo()

        view.keyDown(with: key("r", code: 15))
        click(200, 250)
        drag(CGPoint(x: 230, y: 230), CGPoint(x: 270, y: 270))
        check(boxes.count == 3 && boxes[0] == a && editor.selectedIndices == IndexSet([2]),
              "拿着框工具时在选着的框中间按下：照旧画一个新的（框里起笔画箭头这类不受影响）")
    }

    // MARK: 台阶 20 截图加强

    private static func testScreenshotPlus() {
        // 1. 画了以后还能拖边和角
        let viewSize = CGSize(width: 1512, height: 982)
        let image = makeTestImage(width: 3024, height: 1964)
        let container = NSView(frame: CGRect(origin: .zero, size: viewSize))
        let view = SelectionView(frame: container.bounds, image: image, windowRects: [], scale: 2)
        container.addSubview(view)
        let mosaicSource = MosaicSource(image: image, viewSize: viewSize)
        let editor = AnnotationEditor(container: container, mosaic: mosaicSource)
        defer { editor.tearDown() }
        view.beginEditing(editor, selection: CGRect(x: 100, y: 100, width: 800, height: 600))
        editor.setColor(.red)
        editor.setSize(.thick)
        func drag(_ from: CGPoint, _ to: CGPoint) {
            view.mouseDown(with: mouse(.leftMouseDown, from.x, from.y))
            view.mouseDragged(with: mouse(.leftMouseDragged, (from.x + to.x) / 2, (from.y + to.y) / 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, to.x, to.y))
            view.mouseUp(with: mouse(.leftMouseUp, to.x, to.y))
        }
        view.keyDown(with: key("a", code: 0))
        drag(CGPoint(x: 200, y: 400), CGPoint(x: 600, y: 400))
        let arrow = editor.document.items.first
        check(editor.document.items.count == 1 && editor.canResizeSelection && !editor.canAdjustSelection,
              "画了一个箭头：框还能改大小，但不能整个挪")
        drag(CGPoint(x: 900, y: 100), CGPoint(x: 1000, y: 50))
        check(view.currentSelection == CGRect(x: 100, y: 50, width: 900, height: 650) && editor.document.items.first == arrow
              && editor.selection == view.currentSelection, "画了以后拖右下角：框拉大，箭头留在原处")
        drag(CGPoint(x: 1000, y: 375), CGPoint(x: 400, y: 375))
        check(view.currentSelection == CGRect(x: 100, y: 50, width: 300, height: 650), "拖右边中间的小方块：框缩小到箭头一半")
        if let sel = view.currentSelection,
           let out = AnnotationExporter.export(image: image, viewSize: viewSize, selection: sel, screenOrigin: .zero,
                                               annotations: editor.document.items, mosaic: mosaicSource) {
            let onArrow = pixel(out.image, x: 400, y: (700 - 400) * 2)        // 箭头在框里那半截上
            check(out.image.width == 600 && out.image.height == 1300 && onArrow.r > 200 && onArrow.g < 90,
                  "完成：图只有框里那块（\(out.image.width)×\(out.image.height) 像素），框里那半截箭头在图上")
        } else { check(false, "改了框以后能导出") }
        editor.selectTool(nil)
        let before = view.currentSelection
        drag(CGPoint(x: 250, y: 600), CGPoint(x: 300, y: 650))
        check(view.currentSelection == before, "画了以后在框里空白处拖：框不会整个挪走（拍板）")
        editor.undo()
        check(editor.document.items.isEmpty && view.currentSelection == before, "⌘Z 撤回的是箭头，框不变（改框不算进撤销）")

        // 2. 美化：比例、自选颜色（不显示窗口；改的样式测完换回去）
        let keys = ["beautify.background", "beautify.padding", "beautify.corner", "beautify.shadow", "beautify.custom", "beautify.ratio"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }
        let shot = makeTestImage(width: 400, height: 300)
        let w = BeautifyWindow(image: shot, pointSize: CGSize(width: 200, height: 150), style: .standard)
        check(w.ratioControl.segmentCount == 4 && w.ratioControl.label(forSegment: 1) == "16:9" && w.swatches.count == 11
              && w.customSwatch.toolTip?.hasPrefix("自选") == true, "美化窗口：多一排比例（原样 16:9 4:3 1:1），背景最后多一个\u{201C}自选\u{201D}")
        w.ratioControl.selectedSegment = 1
        w.controlsChanged()
        if let r = w.result() {
            check(abs(r.pointSize.width / r.pointSize.height - 16.0 / 9.0) < 0.01 && Settings.beautifyStyle.ratio == .wide,
                  "选 16:9：成品是 16:9（\(Int(r.pointSize.width))×\(Int(r.pointSize.height)) 点），记住了")
        } else { check(false, "美化 16:9 画得出来") }
        let red = BeautifyColor(r: 1, g: 0, b: 0)
        w.applyCustomColor(red)
        if let r = w.result() {
            let corner = pixel(r.image, x: 2, y: 2)
            check(w.style.background == .solid(red) && w.customSwatch.isSelectedLook && corner.r > 240 && corner.g < 20 && corner.b < 20
                  && !w.ownsColorPanel, "自选一个红色：背景变成纯红，\u{201C}自选\u{201D}色块选着（自检不打开取色盘）")
        } else { check(false, "自选颜色画得出来") }
        let again = BeautifyWindow(image: shot, pointSize: CGSize(width: 200, height: 150), style: Settings.beautifyStyle)
        check(again.style.ratio == .wide && again.style.background == .solid(red) && again.style.custom == red,
              "关掉再美化一张：还是 16:9、还是那个红色")
        var other = again.style
        other.background = .preset(2)
        again.setStyle(other)
        check(Settings.beautifyStyle.custom == red && again.customSwatch.background == .solid(red), "换成别的背景后，自选的颜色还记着")

        // 3. 长截图上标注（不显示；用私有剪贴板、临时文件夹）
        let tallPixels = CGSize(width: 600, height: 6000)
        guard let tallCtx = CGContext(data: nil, width: Int(tallPixels.width), height: Int(tallPixels.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        tallCtx.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        tallCtx.fill(CGRect(origin: .zero, size: tallPixels))
        guard let tall = tallCtx.makeImage() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitLongAnnotate-\(UUID().uuidString)")
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.longannotate.\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: dir); pb.releaseGlobally() }
        let tool = LongShotTool()
        tool.showsToast = false
        let la = tool.annotate(tall, pointSize: NSSize(width: 300, height: 3000), present: false, pasteboard: pb, folder: dir)
        check(!la.window.isVisible && la.editor.toolbar.mode == .pin && la.input.passesScrollWheel
              && la.scrollView.documentView?.frame.size == CGSize(width: 300, height: 3000)
              && abs(la.visibleRect.maxY - 3000) < 1 && la.scrollView.hasVerticalScroller,
              "长截图提示条点\u{201C}标注\u{201D}：长图放进能上下滚的窗口，从最上面开始看，滚轮交给窗口滚")
        la.editor.setColor(.red)
        la.editor.setSize(.thick)
        la.editor.selectTool(.rect)
        la.editor.mouseDown(at: CGPoint(x: 50, y: 100)); la.editor.mouseDragged(to: CGPoint(x: 150, y: 150))
        la.editor.mouseUp(at: CGPoint(x: 200, y: 200))
        la.editor.mouseDown(at: CGPoint(x: 60, y: 2800)); la.editor.mouseUp(at: CGPoint(x: 160, y: 2900))
        _ = la.input.performKeyEquivalent(with: key("a", code: 0, mods: .command))
        _ = la.input.performKeyEquivalent(with: key("d", code: 2, mods: .command))
        check(la.editor.document.items.count == 4, "长截图标注里也能 ⌘A 全选、⌘D 复制（台阶 19 那一套）")
        _ = la.input.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        la.editor.selectTool(.mosaic)
        la.editor.mouseDown(at: CGPoint(x: 20, y: 1500)); la.editor.mouseUp(at: CGPoint(x: 280, y: 1600))
        let started = Date()
        let annotated = la.result()
        info("长截图（600×6000 像素）带马赛克导出一次 \(Int(Date().timeIntervalSince(started) * 1000)) 毫秒")
        if let annotated {
            let edge = pixel(annotated.image, x: 100, y: (3000 - 150) * 2)
            check(annotated.image.width == 600 && annotated.image.height == 6000 && edge.r > 200 && edge.g < 90,
                  "导出：还是原图大小（600×6000 像素），最下面画的框在图上")
        } else { check(false, "长截图标注能导出") }
        la.finish()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(!la.window.isVisible && files.count == 1 && tool.lastAnnotatedURL?.deletingLastPathComponent().path == dir.path
              && pb.data(forType: .png) != nil && tool.annotateWindow == nil,
              "点完成：带标注的复制了、另存了一张新的，窗口关掉")
        let second = tool.annotate(tall, pointSize: NSSize(width: 300, height: 3000), present: false, pasteboard: pb, folder: dir)
        second.editor.selectTool(.rect)
        second.editor.mouseDown(at: CGPoint(x: 50, y: 100)); second.editor.mouseUp(at: CGPoint(x: 200, y: 200))
        second.input.keyDown(with: key("\u{1b}", code: 53))
        check(second.editor.hasSelection == false && tool.annotateWindow === second, "刚画完的选着：第一下 Esc 只取消选中")
        second.input.keyDown(with: key("\u{1b}", code: 53))
        let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(tool.annotateWindow == nil && after.count == 1, "再按 Esc：不要这次画的，不多存文件")
    }

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
        let keys = ["beautify.background", "beautify.padding", "beautify.corner", "beautify.shadow", "beautify.custom", "beautify.ratio"]
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
        check(w.preview.image != nil && w.swatches.count == 11 && w.swatches[0].isSelectedLook,
              "美化窗口：有预览、8 种渐变 + 自动 + 无 + 自选，默认选中蓝紫")
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

        // 3. 存：顺序、去重、收藏、上限、删除、清空、存盘
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
        if let b { store.toggleFavorite(b.id) }
        _ = addText("丁", 5)
        check(store.items.map(\.title) == ["丁", "甲", "丙", "乙"] && store.favorites.map(\.title) == ["乙"],
              "收藏的进收藏栏，历史里照旧按时间排（台阶 14 起不再挤到最上面）")
        for (i, t) in ["1", "2", "3", "4", "5", "6"].enumerated() { _ = addText("新\(t)", Double(10 + i)) }
        check(store.unpinnedCount == 5 && store.items.last?.title == "乙" && store.favorites.first?.title == "乙",
              "超过上限删最旧的，收藏的不算、不删")
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
        check(store.items.count == 1 && store.items[0].title == "乙", "清空历史，收藏的保留")

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
        check(store2.items.first { $0.id == third?.id }?.isFavorite == true && store2.favorites.first?.id == third?.id
              && panel.selectedItem?.id == third?.id, "⌘P 收藏：进收藏栏，这一行留在原处选着")
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
            check(row.titleText.hasPrefix("⭐"), "收藏的那条有星星标记")
        }
        let thumb = ClipboardPanel.thumbnail(png)
        check(thumb != nil && (thumb?.size.width ?? 99) <= 48, "图片在列表里显示成小缩略图")
    }

    // MARK: 识别加强（台阶 15）：翻译（用假的翻译员）、最近的颜色

    @MainActor
    final class FakeTranslator: TextTranslating {
        var calls: [(text: String, source: String?, target: String)] = []
        var failure: TranslateError?
        var hostView: NSView? { nil }
        func translate(_ text: String, from source: String?, to target: String) async throws -> String {
            calls.append((text, source, target))
            if let failure { throw failure }
            return "【\(target)】" + text
        }
        func cancel() {}
    }

    private static func testTranslateAndColors() {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.translate.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

        let fake = FakeTranslator()
        let w = OCRResultWindow(result: OCRResult(lines: ["Hello world, this is MacKit."], codes: []), translator: fake)
        w.pasteboard = pb
        check(w.buttons["translate"] != nil && w.targetPopup.numberOfItems == TranslateLanguages.targets.count
              && w.targetPopup.titleOfSelectedItem == "翻成中文" && !w.hasTranslation, "结果窗口有\u{201C}翻译\u{201D}和语言小菜单；英文默认翻成中文")
        w.translate()
        spin()
        check(w.hasTranslation && w.translationView.string == "【zh-Hans】Hello world, this is MacKit."
              && pb.string(forType: .string) == w.translationView.string, "点翻译：下半部分出译文，译文自动复制")
        check(w.buttons["copy"]?.title == "复制原文" && w.buttons["copyTranslation"]?.isHidden == false
              && w.translateStatus.stringValue.contains("已翻成中文"), "出了译文：有\u{201C}复制原文\u{201D}\u{201C}复制译文\u{201D}")
        w.copyText()
        check(pb.string(forType: .string) == "Hello world, this is MacKit.", "复制原文")
        w.pickTarget("ja")
        spin()
        check(w.userPickedTarget && fake.calls.last?.target == "ja" && w.translationView.string.hasPrefix("【ja】"), "小菜单换成日文：马上按日文再翻")
        w.textView.string = "Hello MacKit"
        w.translate()
        spin()
        check(fake.calls.last?.text == "Hello MacKit" && fake.calls.last?.target == "ja", "改了原文再翻：按改过的翻，语言用你选的")
        fake.failure = .unsupported("日文")
        w.translate()
        spin()
        check(w.translateStatus.stringValue.contains("不支持"), "翻不了：窗口里写明原因")

        let zh = OCRResultWindow(result: OCRResult(lines: ["今天天气不错，我们去公园散步吧。"], codes: []), translator: FakeTranslator())
        zh.pasteboard = pb
        check(zh.targetPopup.titleOfSelectedItem == "翻成英文", "中文默认翻成英文")

        // 系统翻译员：同一种语言、空的，不用真去翻；装没装语言只看不弹
        let system = SystemTranslator()
        let same = awaitResult { () async -> String in
            do { _ = try await system.translate("你好", from: "zh-Hans", to: "zh-Hans"); return "翻了" }
            catch let e as TranslateError { return e.localizedDescription } catch { return "别的错" }
        }
        check(same == "已经是中文了，换一种语言试试", "已经是这种语言了：不翻，直接说明")
        let empty = awaitResult { () async -> Bool in
            do { _ = try await system.translate("   ", from: nil, to: "en"); return false } catch { return (error as? TranslateError) == .empty }
        }
        check(empty == true, "没有字：不翻")
        if let status = awaitResult(timeout: 5, { await SystemTranslator.status(from: "en", to: "zh-Hans") }) {
            let text = switch status {
            case .installed: "已装好"
            case .supported: "支持，要先下载"
            case .unsupported: "不支持"
            @unknown default: "不知道"
            }
            info("这台 Mac 上英文 → 中文的翻译：\(text)")
        }
        let ocrTool = OCRTool()
        check(ocrTool.menuItems().contains { $0.title == "识别并翻译（框选）" }, "菜单里有\u{201C}识别并翻译（框选）\u{201D}")

        // 最近的颜色
        let saved = UserDefaults.standard.object(forKey: "color.recent")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "color.recent") } else { UserDefaults.standard.removeObject(forKey: "color.recent") } }
        Settings.recentColors = []
        RecentColors.record(255, 59, 48)
        RecentColors.record(0, 0, 0)
        RecentColors.record(255, 59, 48)
        check(Settings.recentColors == [0xFF3B30, 0x000000], "取色：记进最近的颜色，同一个不记两遍、挪到最前")
        let menu = RecentColors.menuItem()
        let entries = menu.submenu?.items ?? []
        check(menu.title == "最近的颜色（2 个）" && entries.first?.title == "#FF3B30" && entries.first?.image != nil
              && entries.count > 1 && entries[1].title == "255, 59, 48" && entries[1].isAlternate
              && entries[1].keyEquivalentModifierMask == .option, "菜单里：小色块 + HEX，按住 ⌥ 换成 RGB")
        let shotTool = ScreenshotTool()
        check(shotTool.menuItems().contains { $0.title == "最近的颜色（2 个）" }, "截图那一组里有\u{201C}最近的颜色\u{201D}")
        Settings.recentColors = []
        check(!shotTool.menuItems().contains { $0.title.hasPrefix("最近的颜色") }, "没取过颜色：不显示这一项")
    }

    // MARK: 屏幕画笔（台阶 16）：不显示、不抢键盘

    private static func testScreenPen(recorder: RecorderTool) {
        let tools = AnnotationToolbar.tools(for: .liveDraw)
        let bar = AnnotationToolbar(mode: .liveDraw, standalone: true)
        check(tools == [.pen, .highlighter, .arrow, .rect, .ellipse, .number] && Set(bar.toolButtons.keys) == Set(tools)
              && findButton(in: bar) { $0.toolTip == "清空画的" } != nil, "画笔的小工具：没有马赛克、模糊、文字，有\u{201C}清空\u{201D}")

        let pen = ScreenPenSession(region: CGRect(x: 100, y: 100, width: 400, height: 300), present: false)
        var changes: [Bool] = []
        pen.onChange = { changes.append($0) }
        check(!pen.isDrawing && pen.editor.tool == .pen, "画笔一开始收着，工具是画笔")
        pen.begin()
        // 2026-11-05 验收：全透明的画布点击会穿过去，鼠标不变十字、画不了
        if let catcher = pen.overlay.contentView as? ScreenPenCatcherView, let shot = render(catcher) {
            check(!pen.overlay.ignoresMouseEvents && pixelAlpha(shot, x: 5, y: 5) > 0,
                  "画布明确接鼠标，底色不是全透明（点击不会穿过去）")
        } else {
            check(!pen.overlay.ignoresMouseEvents && pen.overlay.contentView is ScreenPenCatcherView, "画布明确接鼠标，有接点击的底")
        }
        func stroke(_ y: CGFloat) {
            pen.input.mouseDown(with: mouse(.leftMouseDown, 50, y))
            pen.input.mouseDragged(with: mouse(.leftMouseDragged, 120, y + 10))
            pen.input.mouseUp(with: mouse(.leftMouseUp, 200, y + 20))
        }
        stroke(50)
        stroke(150)
        check(pen.isDrawing && changes == [true] && pen.editor.document.items.count == 2, "打开画笔：画了两笔")
        _ = pen.input.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(pen.editor.document.items.count == 1, "⌘Z 撤销一笔")
        pen.editor.toolbar.onClear?()
        check(pen.editor.document.items.isEmpty, "点\u{201C}清空\u{201D}：全没了")
        _ = pen.input.performKeyEquivalent(with: key("z", code: 6, mods: .command))
        check(pen.editor.document.items.count == 1, "清空了也能撤销回来")
        stroke(220)
        pen.input.keyDown(with: key("\u{1b}", code: 53))
        check(pen.isDrawing, "刚画完那一笔还选着：第一下 Esc 只取消选中")
        pen.input.keyDown(with: key("\u{1b}", code: 53))
        check(!pen.isDrawing && changes == [true, false] && pen.editor.document.items.isEmpty && !pen.editor.document.canUndo,
              "再按 Esc：画笔收起，画的一起清掉（撤销记录也清掉）")
        pen.toggle()
        check(pen.isDrawing, "再打开：接着能画")
        pen.close()

        // 录屏里：开始录时造好画笔，它的小工具列进"不录"名单，画布本身要录进去
        if let screen = NSScreen.main {
            let target = RecordTarget.region(id: screen.displayID ?? CGMainDisplayID(), screenFrame: screen.frame,
                                             viewRect: CGRect(x: 100, y: 100, width: 300, height: 200))
            recorder.preparePen(for: target, present: false)
            if let p = recorder.pen {
                check(recorder.excludedWindows.contains(p.toolbarWindowNumber)
                      && !recorder.excludedWindows.contains(CGWindowID(p.overlay.windowNumber)) && p.region == target.globalFrame,
                      "录屏时：画笔盖在录制区域上，小工具不录进去，画的录进去")
            } else { check(false, "录屏时造好画笔") }
            recorder.reset()
            check(recorder.pen == nil, "录完：画笔收掉")
        }
        let hud = RecordingHUD(systemAudio: false, microphone: false)
        hud.setPenOn(true)
        check(hud.buttons["pen"]?.isSelectedLook == true && hud.buttons["pen"]?.toolTip?.contains("⌃⇧D") == true,
              "录制小条上有\u{201C}画笔\u{201D}按钮，开着时亮")
        let free = HotKeyCenter.shared.register(ScreenPenHotKey.standard) {}
        check(free != nil, "平时不占 ⌃⇧D（只在录屏或开着屏幕画笔时才注册）")
        if let free { HotKeyCenter.shared.unregister(free) }

        // 菜单"小工具 → 屏幕画笔"
        let tool = ScreenPenTool()
        check(tool.menuItems().first?.title.hasPrefix("屏幕画笔") == true, "菜单里有\u{201C}屏幕画笔\u{201D}")
        tool.isRecordingBusy = { true }
        tool.start(present: false)
        check(!tool.isOn, "录屏中点屏幕画笔：提示去用录制小条上的画笔")
        tool.isRecordingBusy = { false }
        tool.start(present: false)
        check(tool.isOn && tool.menuItems().first?.title.hasPrefix("收起屏幕画笔") == true, "平时打开屏幕画笔；菜单里变成\u{201C}收起\u{201D}")
        tool.stop()
        check(!tool.isOn && tool.session == nil, "收起屏幕画笔")
    }

    // MARK: 剪贴板加强（台阶 14）：收藏、不记某些软件、连续粘贴。私有剪贴板、临时文件夹，不碰你的历史

    private static func testClipboardPlus() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitClipPlus-\(UUID().uuidString)")
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.clipplus.\(UUID().uuidString)"))
        let target = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.queue.\(UUID().uuidString)"))
        let savedIgnore = UserDefaults.standard.object(forKey: "clipboard.ignoredApps")
        defer {
            try? FileManager.default.removeItem(at: dir)
            pb.releaseGlobally()
            target.releaseGlobally()
            if let savedIgnore { UserDefaults.standard.set(savedIgnore, forKey: "clipboard.ignoredApps") }
            else { UserDefaults.standard.removeObject(forKey: "clipboard.ignoredApps") }
        }
        let store = ClipboardStore(directory: dir, limit: 50)
        @discardableResult
        func add(_ t: String) -> ClipboardItem? {
            pb.clearContents(); pb.setString(t, forType: .string)
            guard case .success(let s) = ClipboardReader.read(pb, source: nil, ignoredApps: []) else { return nil }
            return store.add(s)
        }
        add("北京市朝阳区某某路 1 号")
        add("第四条")
        guard let a = add("你好，请问有什么可以帮您"), let c = add("发票抬头：某某公司") else { check(false, "剪贴板加强：准备几条"); return }

        // 收藏：⌘P、⌘R 起名、搜名字、Tab、排顺序、存盘、老文件里的置顶
        let tool = ClipboardTool(store: store, pasteboard: target)
        let panel = tool.makePanel()
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        defer { panel.close(returnFocus: false) }
        panel.select(panel.shown.firstIndex { $0.id == a.id } ?? 0)
        _ = panel.handleKey(key("p", code: 35, mods: .command))
        _ = panel.handleKey(key("r", code: 15, mods: .command))
        check(panel.renamingID == a.id, "⌘R：搜索框变成起名字的地方")
        panel.searchField.stringValue = "常用开场白"
        _ = panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(store.items.first { $0.id == a.id }?.favoriteName == "常用开场白" && panel.renamingID == nil
              && panel.searchField.stringValue.isEmpty, "起好名字回车：存下，搜索框恢复")
        _ = panel.handleKey(key("\t", code: 48))
        check(panel.tab == .favorites && panel.shown.map(\.id) == [a.id], "Tab：切到收藏栏，只有收藏的")
        panel.searchField.stringValue = "开场白"
        panel.reload()
        check(panel.shown.first?.id == a.id, "收藏栏里搜名字能搜到")
        panel.searchField.stringValue = ""
        _ = panel.handleKey(key("\t", code: 48))
        panel.select(panel.shown.firstIndex { $0.id == c.id } ?? 0)
        _ = panel.handleKey(key("p", code: 35, mods: .command))
        check(store.favorites.map(\.id) == [c.id, a.id], "再收藏一条：新收藏的排在收藏栏最前")
        panel.setTab(.favorites)
        panel.select(0)
        _ = panel.handleKey(key("", code: 125, mods: [.command, .option]))
        check(store.favorites.map(\.id) == [a.id, c.id], "⌥⌘↓：在收藏栏里往下挪")
        let reopened = ClipboardStore(directory: dir, limit: 50)
        reopened.load()
        check(reopened.favorites.map(\.id) == [a.id, c.id] && reopened.favorites.first?.favoriteName == "常用开场白",
              "退出再打开：收藏的顺序和名字都在")
        store.clearUnpinned()
        check(store.items.count == 2 && store.favorites.count == 2, "清空历史：收藏的不动")
        // 老版本存的：只有"置顶"，没有名字和顺序
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           var json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for i in json.indices { json[i].removeValue(forKey: "favoriteName"); json[i].removeValue(forKey: "favoriteOrder") }
            let oldDir = dir.appendingPathComponent("old")
            try? FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: json).write(to: oldDir.appendingPathComponent("index.json"))
            let old = ClipboardStore(directory: oldDir, limit: 50)
            old.load()
            check(old.favorites.count == 2 && old.favorites.allSatisfy { $0.favoriteName == nil }, "老版本的置顶读进来自动变成收藏")
        } else { check(false, "老版本的置顶读进来") }

        // 不记某些软件
        let me = Bundle.main.bundleIdentifier ?? "local.mackit.MacKit"
        pb.clearContents(); pb.setString("从名单里的软件复制的", forType: .string)
        if case .failure(.ignoredApp) = ClipboardReader.read(pb, source: .current, ignoredApps: [me]) {
            check(true, "名单里的软件复制的：不进历史")
        } else { check(false, "名单里的软件复制的不进历史") }
        if case .success = ClipboardReader.read(pb, source: .current, ignoredApps: []) { check(true, "不在名单里：照常记") }
        else { check(false, "不在名单里照常记") }
        UserDefaults.standard.removeObject(forKey: "clipboard.ignoredApps")
        check(ClipboardIgnoreList.ids == ["com.apple.keychainaccess"], "名单一开始就有钥匙串访问")
        ClipboardIgnoreList.add("com.example.chat")
        ClipboardIgnoreList.add("com.example.chat")
        check(ClipboardIgnoreList.ids == ["com.apple.keychainaccess", "com.example.chat"], "加进名单（重复加只算一次）")
        let ignoreWindow = ClipboardIgnoreWindow()
        ignoreWindow.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        ignoreWindow.removeSelected()
        check(ClipboardIgnoreList.ids == ["com.apple.keychainaccess"] && ignoreWindow.ids.count == 1, "名单小窗口里删掉一个")
        if let front = ClipboardIgnoreList.frontApp?.localizedName {
            check(tool.menuItems().contains { $0.title.contains("「\(front)」") }, "菜单里一键\u{201C}不记「\(front)」\u{201D}")
        }

        // 连续粘贴（不挂真的钩子：直接调"按了 ⌘V"）
        let queue = tool.queue
        guard let b = add("张三"), let c = add("男"), let d = add("28") else { check(false, "连续粘贴：准备几条"); return }
        target.clearContents(); target.setString("原来剪贴板里的", forType: .string)
        check(tool.menuItems().contains { $0.title.hasPrefix("开始连续粘贴") }, "菜单里有\u{201C}开始连续粘贴\u{201D}")
        queue.start(with: [b, c])
        check(queue.isActive && queue.statusText.hasPrefix("连续粘贴：已排 2 条"), "排好两条：小条写着已排 2 条")
        queue.didCopy(d)
        check(queue.queue.count == 3, "还没开始贴：新复制的排到队尾")
        queue.willPaste()
        check(target.string(forType: .string) == b.title && queue.statusText.hasPrefix("连续粘贴 2 / 3"), "按 ⌘V：换成第一条")
        queue.didCopy(a)
        check(queue.queue.count == 3, "开始贴以后新复制的不进队伍")
        queue.willPaste()
        check(target.string(forType: .string) == c.title, "再按 ⌘V：第二条")
        if case .failure(.ownRestore) = ClipboardReader.read(target, source: nil, ignoredApps: []) { check(true, "换进去的带着 MacKit 的标记，不会又记进历史") }
        else { check(false, "换进去的带标记") }
        queue.willPaste()
        check(target.string(forType: .string) == d.title && queue.queue.isFinished, "第三条，贴完了")
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        check(!queue.isActive && target.string(forType: .string) == "原来剪贴板里的", "贴完自动结束，剪贴板换回开始之前的")

        queue.start()
        queue.didCopy(a)
        queue.didCopy(b)
        queue.willPaste()
        check(target.string(forType: .string) == a.title, "菜单开始后按顺序复制：⌘V 先贴第一段")
        queue.finish()
        queue.start(with: [d, b])
        store.delete(d.id)
        queue.willPaste()
        check(target.string(forType: .string) == b.title, "排着的那条被删了：跳过它，贴下一条")
        queue.finish()
        check(!queue.isActive && target.string(forType: .string) == "原来剪贴板里的", "中途点结束：剪贴板也换回原来的")

        add("第五条")                                               // 前面清空过历史，再补一条凑够三条
        var queued: [UUID] = []
        panel.onQueue = { items in queued = items.map(\.id) }
        panel.setTab(.all)
        panel.show(near: CGPoint(x: 400, y: 400), present: false)
        panel.select(2)
        panel.toggleSelect(0)
        let expected = [panel.shown[2].id, panel.shown[0].id]
        _ = panel.handleKey(key("\r", code: 36, mods: .command))
        check(queued == expected, "小窗口里 ⌘ 点选两条、⌘回车：按点的先后排进连续粘贴")
    }

    // MARK: 录屏（台阶 5）。真的录屏要弹系统窗口、占屏幕，不在这里做；这里测"录哪里、怎么录"算得对不对

    private static func testRecorder(_ tool: RecorderTool) {
        check(tool.state == .idle && tool.hotKeyRegistered, "录屏快捷键 \(Settings.recordHotKey?.display ?? "没设") 已注册，平时是空闲状态")
        check(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              "App 里写明了麦克风用途（没写的话一要麦克风权限就会闪退）")
        let titles = tool.menuItems().map(\.title)
        check(titles.contains { $0.hasPrefix("录屏（") }, "菜单里有录屏（画质、保存位置、录完打开预览在设置窗口的录屏页）")

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

    // MARK: 台阶 21 录屏自动推近（不真的录屏、不显示窗口、不弹提示；鼠标记录存在临时文件夹）

    private static func testAutoZoom() {
        // 1. 记鼠标：只在"在录"时记，点击只算录的那块里面的
        var now: Double? = nil
        let tracker = MouseTracker(frame: CGRect(x: 100, y: 100, width: 200, height: 100)) { now }
        tracker.click(at: CGPoint(x: 150, y: 150))
        check(tracker.track.samples.isEmpty && tracker.track.clicks.isEmpty, "还没开始录（或暂停中）：鼠标不记")
        now = 1.0
        tracker.sample(CGPoint(x: 150, y: 150))
        tracker.click(at: CGPoint(x: 200, y: 175))
        tracker.click(at: CGPoint(x: 500, y: 150))
        let recorded = tracker.stop(duration: 3)
        check(recorded.samples.first == .init(t: 1, x: 0.25, y: 0.5) && recorded.clicks == [1.0] && recorded.samples.count == 3
              && recorded.duration == 3, "在录时：位置换成画面里的比例、点击记下时刻；点到录的那块外面不算")

        // 2. 存鼠标记录：按视频文件名对上，只留最近几个
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitZoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = dir.appendingPathComponent("tracks")
        let videos = (1...3).map { dir.appendingPathComponent("MacKit_录屏_\($0).mp4") }
        for (i, v) in videos.enumerated() {
            MouseTrackStore.save(recorded, for: v, in: tracks, keep: 2)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 3) * 60)],
                                                   ofItemAtPath: MouseTrackStore.url(for: v, in: tracks).path)
        }
        MouseTrackStore.save(recorded, for: videos[2], in: tracks, keep: 2)
        check(MouseTrackStore.load(for: videos[2], in: tracks) == recorded && MouseTrackStore.load(for: videos[1], in: tracks) != nil
              && MouseTrackStore.load(for: videos[0], in: tracks) == nil, "鼠标记录按视频文件名存取，只留最近的（最老的删掉）")

        // 3. 推近版视频：左上红、右上绿、左下蓝、右下白；在红的那块点了一下 → 推近后整个画面都是红的
        let source = dir.appendingPathComponent("四色.mp4")
        let size = CGSize(width: 320, height: 180)
        guard awaitResult(timeout: 20, { () async -> Bool in
            (try? await writeQuadrantVideo(to: source, seconds: 2, size: size)) != nil
        }) == true else { check(false, "造一段四色的小视频"); return }
        let samples = stride(from: 0.0, through: 2.0, by: 1.0 / 30).map { MouseTrack.Sample(t: $0, x: 0.25, y: 0.25) }
        let track = MouseTrack(samples: samples, clicks: [0.5], duration: 2)
        let plan = AutoZoom.plan(track, config: AutoZoomConfig())
        func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g < 90 && p.b < 90 }
        func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 200 && p.g > 200 && p.b > 200 }
        let zoomed = dir.appendingPathComponent("四色-推近.mp4")
        let exported = awaitResult(timeout: 30) { () async -> Bool in
            (try? await VideoTools.exportZoomed(source, plan: plan, range: nil, to: zoomed)) != nil
        } == true
        let before = awaitResult(timeout: 10) { await frame(of: zoomed, at: 0.05) } ?? nil
        let during = awaitResult(timeout: 10) { await frame(of: zoomed, at: 1.2) } ?? nil
        let length = awaitResult(timeout: 10) { await VideoTools.duration(of: zoomed) } ?? 0
        if exported, let before, let during {
            let w = before.width, h = before.height
            check(w == 320 && h == 180 && abs(length - 2) < 0.15, "导出推近版：尺寸、时长和原视频一样（\(w)×\(h)，\(String(format: "%.2f", length)) 秒）")
            check(isWhite(pixel(before, x: w - 6, y: h - 6)) && isRed(pixel(before, x: 6, y: 6)), "点之前：全景（右下角还是白的）")
            check(isRed(pixel(during, x: w - 6, y: h - 6)) && isRed(pixel(during, x: w / 2, y: h / 2)),
                  "点了以后：推近到点的地方，整个画面都是那块红的")
        } else { check(false, "推近版导出、取帧") }

        let trimmedZoom = dir.appendingPathComponent("四色-剪过-推近.mp4")
        let range = CMTimeRange(start: CMTime(seconds: 0.6, preferredTimescale: 600), duration: CMTime(seconds: 1.2, preferredTimescale: 600))
        _ = awaitResult(timeout: 30) { () async -> Bool in
            (try? await VideoTools.exportZoomed(source, plan: plan, range: range, to: trimmedZoom)) != nil
        }
        let trimLength = awaitResult(timeout: 10) { await VideoTools.duration(of: trimmedZoom) } ?? 0
        if let f = awaitResult(timeout: 10, { await frame(of: trimmedZoom, at: 0.5) }) ?? nil {
            check(abs(trimLength - 1.2) < 0.15 && isRed(pixel(f, x: f.width - 6, y: f.height - 6)),
                  "剪了头尾再推近：只留剪好的那段（\(String(format: "%.2f", trimLength)) 秒），推近的时刻还对得上")
        } else { check(false, "剪过的推近版取帧") }

        let gif = dir.appendingPathComponent("四色-推近.gif")
        let frames = awaitResult(timeout: 30) { () async -> Int in
            (try? await VideoTools.makeGIF(from: source, to: gif, maxWidth: 320, fps: 10, zoom: plan)) ?? 0
        } ?? 0
        if let src = CGImageSourceCreateWithURL(gif as CFURL, nil), frames >= 15,
           let g0 = CGImageSourceCreateImageAtIndex(src, 0, nil), let g12 = CGImageSourceCreateImageAtIndex(src, 12, nil) {
            check(isWhite(pixel(g0, x: g0.width - 6, y: g0.height - 6)) && isRed(pixel(g12, x: g12.width - 6, y: g12.height - 6)),
                  "勾着推近存成 GIF：GIF 也是推近的")
        } else { check(false, "推近的 GIF 存得出来") }

        // 4. 预览窗口（只造不显示）
        let w = RecordingPreviewWindow(url: source, track: track)
        w.showsToast = false
        defer { w.window.close() }
        check(w.zoomBox.isEnabled && w.zoomPopup.itemTitles == ["1.5 倍", "2 倍", "2.5 倍"] && w.zoomPopup.titleOfSelectedItem == "2 倍"
              && !w.zoomPopup.isEnabled, "预览窗口：多一个\u{201C}自动推近\u{201D}的勾，旁边能选 1.5 / 2 / 2.5 倍，默认 2 倍")
        _ = awaitResult(timeout: 10) { await w.setZoom(true) }
        check(w.isZoomOn && w.playerView.player?.currentItem?.videoComposition != nil && w.zoomPlan?.config.factor == 2 && w.zoomPopup.isEnabled,
              "勾上：播放器马上换成推近的画面（播放就能看到）")
        w.zoomPopup.selectItem(at: 2)
        check(w.zoomPlan?.config.factor == 2.5, "换成 2.5 倍")
        let saved1 = awaitResult(timeout: 30) { await w.saveZoomed() } ?? nil
        let saved2 = awaitResult(timeout: 30) { await w.saveZoomed() } ?? nil
        check(saved1?.lastPathComponent == "四色-推近 2.mp4" && saved2?.lastPathComponent == "四色-推近 3.mp4"
              && FileManager.default.fileExists(atPath: source.path), "点保存：另存一份\u{201C}-推近\u{201D}（已经有了就加 2、3），原视频还在")
        _ = awaitResult(timeout: 10) { await w.setZoom(false) }
        check(!w.isZoomOn && w.playerView.player?.currentItem?.videoComposition == nil, "去掉勾：回到原样")
        info("预览窗口下面那排按钮要 \(Int(w.barWidth)) 点宽，窗口最窄 \(Int(w.window.minSize.width)) 点")
        check(w.window.minSize.width >= w.barWidth && w.barWidth > 520, "预览窗口不会比下面那排按钮还窄（竖着的视频也放得下）")
        let old = RecordingPreviewWindow(url: source)
        defer { old.window.close() }
        check(!old.zoomBox.isEnabled && old.zoomBox.title.contains("没有鼠标记录"), "没有鼠标记录（录的单个窗口、以前录的）：\u{201C}自动推近\u{201D}灰着，写着原因")
    }

    /// 造一段四色的假视频：左上红、右上绿、左下蓝、右下白（H.264、没有声音）
    nonisolated private static func writeQuadrantVideo(to url: URL, seconds: Double, size: CGSize) async throws {
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
        let fps = 30, w = Int(size.width), h = Int(size.height)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let left = x < w / 2, top = y < h / 2
                        let (r, g, b): (UInt8, UInt8, UInt8) = top ? (left ? (255, 0, 0) : (0, 255, 0)) : (left ? (0, 0, 255) : (255, 255, 255))
                        let o = y * row + x * 4
                        p[o] = b; p[o + 1] = g; p[o + 2] = r; p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VideoToolError.exportUnavailable }
    }

    /// 视频某一刻的画面
    nonisolated private static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try? await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
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
        // 第二版加了"识别并翻译""开始连续粘贴""不记「当前软件」"；自检环境里还多两行提醒（录屏权限、自动粘贴没开）
        check(rows.count <= 32, "菜单第一层 \(rows.count) 行（整理前 40 多行；你那边没有那两行提醒）")
        // 台阶 17：各组的"X设置"子菜单都收进设置窗口，菜单最下面只留"设置…"
        let oldSubs = ["截图设置", "录屏设置", "剪贴板设置", "识别设置"].filter { t in menu.items.contains { $0.title == t } }
        check(oldSubs.isEmpty, "菜单里没有\u{201C}截图设置\u{201D}\u{201C}录屏设置\u{201D}这些子菜单了\(oldSubs.isEmpty ? "" : "（还有：\(oldSubs.joined(separator: "、"))）")")
        let tail = menu.items.suffix(2)
        check(tail.first?.title == "设置…" && tail.first?.keyEquivalent == "," && tail.first?.keyEquivalentModifierMask == .command
              && tail.last?.title == "退出 MacKit", "菜单最下面：设置…（⌘,）、退出 MacKit")
        let everything = allTitles(menu)
        let mustHave = ["截取整个屏幕", "长截图（框选后往下滚，拼成一张长图）", "延时截图", "3 秒后截图", "贴图（剪贴板里的图片或文字）",
                        "录屏（框选 / 单击窗口 / 整屏）", "识别文字（框选）", "测量（自动量宽高、拖框量大小）", "排窗口（系统自带的快捷键）",
                        "30 分钟", "关于 MacKit", "设置…", "退出 MacKit"]
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

        // 欢迎窗口（不显示）：选一套 → 六个快捷键一起换；测完换回原样（台阶 17 起还有各自改过的键位）
        let savedDefaults = snapshotDefaults()
        defer { restoreDefaults(savedDefaults) }
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
        check(Settings.hotKeyScheme == .control && Settings.screenshotHotKey?.display == "⌃⇧1" && changed == [.control]
              && welcome.schemeButtons[.control]?.state == .on, "欢迎窗口里选 ⌃⇧ 那套：六个快捷键一起换，各积木重新注册")
        welcome.choose(.command)
        check(Settings.hotKeyScheme == .command && Settings.measureHotKeyIndex == 0, "再换回 ⌘ 那套")
        Settings.clipboardHotKeyIndex = 1
        check(Settings.hotKeyScheme == nil, "单独改过某一个快捷键：哪套都不算，欢迎窗口里两个都不选")
        welcome.choose(.command)
        Settings.setHotKey(HotKeyCombo(keyCode: 40, modifiers: [.control, .option, .shift]), for: .ocr)
        check(Settings.hotKeyScheme == nil, "在设置窗口里随便按了一个：也是哪套都不算")
        welcome.choose(.command)
        check(Settings.hotKeyScheme == .command && !Settings.isCustomHotKey(.ocr), "再选一套：各自改过的也一起换回这一套")
        welcome.dryRun = true
        let launchBefore = LaunchAtLogin.status
        check(welcome.launchBox.title.hasPrefix("开机自动启动") && welcome.launchBox.isOn == LaunchAtLogin.isOn,
              "欢迎窗口里有\u{201C}开机自动启动\u{201D}的勾，照系统的实情显示（新用户默认不勾）")
        welcome.launchBox.toggleForTest()
        check(LaunchAtLogin.status == launchBefore, "自检里点了欢迎窗口的勾，也不真的去加登录项")
        welcome.window.close()

        // 关于菜单
        let aboutTitles = menu?.items.first { $0.title == "关于 MacKit" }?.submenu?.items.map(\.title) ?? []
        check(aboutTitles.contains("使用说明（权限、快捷键）…") && aboutTitles.contains("打开项目主页") && aboutTitles.contains("检查更新…")
              && !aboutTitles.contains("看看有没有新版本")
              && AppLinks.home.absoluteString == "https://github.com/itzzan/MacKit" && AppLinks.releases.path == "/itzzan/MacKit/releases",
              "关于 MacKit：使用说明、项目主页、检查更新…")
        // 2.0 起：老用户第一次打开新的大版本弹一次提示条（台阶 18）
        check(WhatsNew.shouldShow(firstLaunch: .nothing, lastVersion: nil, current: "2.0.0")
              && WhatsNew.shouldShow(firstLaunch: .keepOldHotKeys, lastVersion: nil, current: "2.0.0")
              && WhatsNew.shouldShow(firstLaunch: .nothing, lastVersion: "1.6.0", current: "2.0.0"),
              "从 1.x 升到 2.0：第一次打开弹\u{201C}MacKit 2.0 装好了\u{201D}")
        check(!WhatsNew.shouldShow(firstLaunch: .welcome, lastVersion: nil, current: "2.0.0"), "新用户第一次装 2.0：只有欢迎窗口，不弹这个")
        check(!WhatsNew.shouldShow(firstLaunch: .nothing, lastVersion: "2.0.0", current: "2.0.0")
              && !WhatsNew.shouldShow(firstLaunch: .nothing, lastVersion: "2.0.0", current: "2.1.0"),
              "再打开、升到 2.1：不再弹")
        check(!WhatsNew.shouldShow(firstLaunch: .nothing, lastVersion: nil, current: "1.6.0"), "1.x 自己不弹")
        let whatsNew = Toast.makeActionsPanel(WhatsNew.message(for: "2.0.0"), actions: [("看看都有什么", {})])
        check(WhatsNew.message(for: "2.0.0").hasPrefix("MacKit 2.0 装好了") && whatsNew.frame.width < 760 && !whatsNew.isVisible
              && AppLinks.releaseNotes("2.0.0").absoluteString == "https://github.com/itzzan/MacKit/releases/tag/v2.0.0",
              "提示条写着\u{201C}MacKit 2.0 装好了\u{201D}，\u{201C}看看都有什么\u{201D}打开 GitHub 上 2.0 的更新说明（\(Int(whatsNew.frame.width)) 点宽）")
        let parts = AppInfo.version.split(separator: ".").compactMap { Int($0) }
        check(parts.count == 3 && parts[0] >= 1, "版本号是三段数字、1 以上：\(AppInfo.version)")
    }

    // MARK: 台阶 17 设置窗口

    /// MacKit 自己的设置全拍一份（测完改回去，你的设置一点不动）
    private static func snapshotDefaults() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    private static func restoreDefaults(_ before: [String: Any]) {
        let after = snapshotDefaults()
        for key in Set(before.keys).union(after.keys) where (before[key] as? NSObject) != (after[key] as? NSObject) {
            if let v = before[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// 在一页里按名字找按钮
    private static func button(_ title: String, in view: NSView) -> NSButton? {
        if let b = view as? NSButton, b.title == title { return b }
        for sub in view.subviews { if let b = button(title, in: sub) { return b } }
        return nil
    }

    /// 假的 GitHub 回答
    private final class FakeReply: @unchecked Sendable {
        var data: Data?
        var asked: [URL] = []
    }

    private static func release(_ tag: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": "  新东西：设置窗口  ",
                                                     "html_url": "https://github.com/itzzan/MacKit/releases/tag/\(tag)"])
    }

    private static func testSettingsWindow(hooks appHooks: SettingsHooks, menu: NSMenu?) {
        let savedDefaults = snapshotDefaults()
        let wasCustom = HotKeyAction.allCases.map(Settings.isCustomHotKey)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitSettings-\(UUID().uuidString)")
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.selftest.settings.\(UUID().uuidString)"))
        defer {
            restoreDefaults(savedDefaults)
            appHooks.reloadHotKeys()                       // 快捷键挂回测之前的样子
            try? FileManager.default.removeItem(at: dir)
            pb.releaseGlobally()
        }

        // 检查更新：用假的回答，不真的联网
        let reply = FakeReply()
        let checker = UpdateChecker { url in
            reply.asked.append(url)
            guard let d = reply.data else { throw URLError(.notConnectedToInternet) }
            return d
        }
        reply.data = release("v1.0.0")
        check(awaitResult(timeout: 3) { await checker.check(current: "1.6.0") } == .upToDate("1.6.0"), "检查更新：GitHub 上是 1.0.0、你是 1.6.0 → 已是最新")
        check(reply.asked.first?.host == "api.github.com" && reply.asked.first?.path == "/repos/itzzan/MacKit/releases/latest",
              "检查更新只问 GitHub 的\u{201C}最新发布\u{201D}，地址里不带你的任何东西")
        reply.data = release("v2.0.0")
        check(awaitResult(timeout: 3) { await checker.check(current: "1.6.0") }
              == .newer(version: "2.0.0", notes: "新东西：设置窗口", page: URL(string: "https://github.com/itzzan/MacKit/releases/tag/v2.0.0")!),
              "检查更新：GitHub 上有 v2.0.0 → 有新版，带上更新说明和下载页")
        reply.data = Data("不是 JSON".utf8)
        check(awaitResult(timeout: 3) { await checker.check(current: "1.6.0") } == .failed("GitHub 的回答看不懂，等会儿再试"), "检查更新：回答看不懂 → 说等会儿再试")
        reply.data = nil
        check(awaitResult(timeout: 3) { await checker.check(current: "1.6.0") } == .failed("连不上 GitHub，等会儿再试"), "检查更新：连不上 → 连不上 GitHub，等会儿再试")
        check(UpdateChecker.summary(.upToDate("1.6.0")) == "已是最新版本 1.6.0", "已是最新时写\u{201C}已是最新版本 1.6.0\u{201D}")

        // 设置窗口（不显示）：用临时的剪贴板历史，不碰你真的
        let store = ClipboardStore(directory: dir, limit: 50)
        for t in ["第一条", "第二条", "收藏的这条"] {
            pb.clearContents(); pb.setString(t, forType: .string)
            if case .success(let snap) = ClipboardReader.read(pb, source: nil, ignoredApps: []) { _ = store.add(snap) }
        }
        if let fav = store.items.first { store.toggleFavorite(fav.id) }
        HotKeyAction.allCases.forEach(Settings.resetHotKey)          // 从“都没单独改过”开始测（测完换回你的）
        appHooks.reloadHotKeys()
        var hooks = appHooks
        var reloads = 0, welcomes = 0, ignores = 0
        hooks.reloadHotKeys = { reloads += 1; appHooks.reloadHotKeys() }
        hooks.showWelcome = { welcomes += 1 }
        hooks.openIgnoreList = { ignores += 1 }
        hooks.clearClipboard = { store.clearUnpinned() }
        hooks.clipboardCounts = { (store.items.count, store.items.filter(\.pinned).count) }
        hooks.updateChecker = checker
        hooks.dryRun = true
        let settings = SettingsWindow(hooks: hooks)
        defer { settings.window.close() }
        check(settings.tabs.tabViewItems.map(\.label) == ["通用", "快捷键", "截图", "录屏", "剪贴板"] && settings.tabs.tabStyle == .toolbar
              && settings.tabs.tabViewItems.allSatisfy { $0.image != nil } && !settings.window.isVisible,
              "设置窗口：上面一排图标分页——通用、快捷键、截图、录屏、剪贴板（自检不显示）")
        for pane in SettingsWindow.Pane.allCases { _ = settings.panes[pane]?.view }        // 每页都建出来
        settings.select(.record)
        check(settings.tabs.selectedTabViewItemIndex == 3, "点\u{201C}录屏\u{201D}切到录屏页")

        // 通用：开机启动只看状态、不真的去加；检查更新；权限；欢迎窗口
        guard let general = settings.panes[.general] as? GeneralPane, let shortcuts = settings.panes[.shortcuts] as? ShortcutsPane,
              let shot = settings.panes[.screenshot] as? ScreenshotPane, let record = settings.panes[.record] as? RecordPane,
              let clip = settings.panes[.clipboard] as? ClipboardPane else { check(false, "设置窗口五页都在"); return }
        let launchBefore = LaunchAtLogin.status
        check(general.launchBox.isOn == LaunchAtLogin.isOn && general.launchStatus.stringValue == LaunchAtLogin.statusText
              && general.approveButton.isHidden == !LaunchAtLogin.needsApproval,
              "通用页：开机自动启动照系统的实情显示（现在：\(LaunchAtLogin.statusText)）")
        general.launchBox.toggleForTest()
        check(LaunchAtLogin.status == launchBefore, "自检里点了开机启动的勾，也不真的去加登录项")
        general.reload()
        reply.data = release("v9.0.0")
        general.checkUpdate()
        let deadline = Date().addingTimeInterval(3)
        while !general.updateButton.isEnabled && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(general.updateLabel.stringValue.hasPrefix("有新版本 9.0.0") && general.updateLabel.stringValue.contains("新东西")
              && !general.downloadButton.isHidden, "通用页点\u{201C}检查更新\u{201D}：有新版时写版本号和更新说明，出现\u{201C}去下载\u{201D}")
        general.showUpdate(.failed("连不上 GitHub，等会儿再试"))
        check(general.updateLabel.stringValue == "连不上 GitHub，等会儿再试" && general.downloadButton.isHidden, "连不上时没有\u{201C}去下载\u{201D}")
        check(general.permissionLabels.keys.sorted() == ["access", "camera", "mic", "screen"]
              && general.permissionLabels["screen"]?.stringValue == (ScreenPermission.isGranted ? "已开启 ✓" : "未开启"),
              "通用页：屏幕录制、辅助功能、麦克风、摄像头四种权限各自开没开")
        button("再看一次欢迎窗口", in: general.view)?.performClick(nil)
        check(welcomes == 1, "通用页：再看一次欢迎窗口")

        // 快捷键：八个都在；录的时候先把 MacKit 自己的快捷键全摘掉
        let k = HotKeyCombo(keyCode: 40, modifiers: [.control, .option, .shift])          // ⌃⌥⇧K，几乎没人用
        check(shortcuts.fields.count == 8 && shortcuts.fields[.screenshot]?.title == Settings.hotKey(.screenshot)?.display
              && shortcuts.fields[.screenPen]?.title == Settings.hotKey(.screenPen)?.display,
              "快捷键页：截图、贴图、显示 / 隐藏贴图、剪贴板、录屏、识别文字、测量、屏幕画笔都在一张表里")
        guard let shotField = shortcuts.fields[.screenshot], let recordField = shortcuts.fields[.record],
              let measureField = shortcuts.fields[.measure], let clipField = shortcuts.fields[.clipboard] else { return }
        shotField.startRecording(listen: false)
        check(shotField.isRecording && shotField.title == "按下新的快捷键…" && HotKeyCenter.shared.isSuspended
              && HotKeyCenter.shared.registeredCount == 0, "点一个快捷键：写着\u{201C}按下新的快捷键…\u{201D}，MacKit 自己的快捷键先全摘掉（按 ⌘1 不会截图）")
        shotField.handle(keyCode: 1, modifiers: [])
        check(shotField.isRecording && shortcuts.message.stringValue.hasPrefix("要带上"), "单按 S：不让设，说要带上 ⌘ ⌃ ⌥")
        shotField.handle(keyCode: 1, modifiers: [.shift])
        check(shotField.isRecording && shortcuts.message.stringValue.hasPrefix("要带上"), "⇧S 也不让设（打大写字母会被截走）")
        shotField.handle(keyCode: 21, modifiers: [.shift, .command])
        check(shotField.isRecording && shortcuts.message.stringValue.contains("系统截图"), "⇧⌘4：提醒是系统截图用的，换一个")
        shotField.handle(keyCode: 12, modifiers: [.control, .option, .command])
        check(shotField.isRecording && shortcuts.message.stringValue.contains("紧急退出"), "⌃⌥⌘Q：紧急退出固定不能占")
        let before = reloads, old = Settings.hotKey(.screenshot)
        shotField.handle(keyCode: 40, modifiers: [.control, .option, .shift])
        check(!shotField.isRecording && Settings.hotKey(.screenshot) == k && shotField.title == "⌃⌥⇧K"
              && !HotKeyCenter.shared.isSuspended && reloads == before + 1, "按 ⌃⌥⇧K：截图改成 ⌃⌥⇧K，录完把快捷键挂回去")
        check(HotKeyCenter.shared.isRegistered(k) && !(old.map(HotKeyCenter.shared.isRegistered) ?? false),
              "改完马上重新注册：⌃⌥⇧K 真的挂上了，原来的摘掉了（不用重开 MacKit）")
        if let menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            check(menu.items.contains { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask == [.control, .option, .shift] },
                  "菜单里截图那一项右边跟着写 ⌃⌥⇧K")
        }
        check(shortcuts.resetButtons[.screenshot]?.isEnabled == true && shortcuts.resetButtons[.record]?.isEnabled == false,
              "改过的那一行\u{201C}恢复默认\u{201D}能点，没改过的灰着")

        recordField.startRecording(listen: false)
        recordField.handle(keyCode: 40, modifiers: [.control, .option, .shift])
        check(recordField.isRecording && shortcuts.message.stringValue.contains("截图") && Settings.hotKey(.record) != k,
              "录屏也想设 ⌃⌥⇧K：不让设，说和截图撞了")
        recordField.handle(keyCode: 53, modifiers: [])
        check(!recordField.isRecording && !HotKeyCenter.shared.isSuspended && shortcuts.message.stringValue == "没改", "Esc：不改了")

        clipField.startRecording(listen: false)
        recordField.startRecording(listen: false)
        check(!clipField.isRecording && recordField.isRecording && HotKeyCenter.shared.isSuspended, "同时只录一个：点了另一个，前一个算放弃")
        settings.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        check(!recordField.isRecording && !HotKeyCenter.shared.isSuspended, "切到别的窗口：正在录的算放弃，快捷键挂回去")

        clipField.startRecording(listen: false)
        clipField.handle(keyCode: 96, modifiers: [])
        check(Settings.hotKey(.clipboard)?.display == "F5", "F5 可以单按")

        measureField.startRecording(listen: false)
        measureField.handle(keyCode: 51, modifiers: [])
        check(Settings.hotKey(.measure) == nil && measureField.title == "未设置" && shortcuts.message.stringValue.contains("不要快捷键"),
              "⌫ 清掉：测量不要快捷键了")
        if let menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            let item = menu.items.first { $0.title.hasPrefix("测量（") }
            check(item != nil && item?.keyEquivalent == "", "清掉以后菜单里照样能点测量，只是右边没有快捷键")
        }

        shortcuts.resetButtons[.screenshot]?.performClick(nil)
        check(!Settings.isCustomHotKey(.screenshot) && Settings.hotKey(.screenshot) == HotKeyAction.screenshot.presetCombo
              && shotField.title == HotKeyAction.screenshot.presetCombo.display && shortcuts.resetButtons[.screenshot]?.isEnabled == false,
              "截图\u{201C}恢复默认\u{201D}：变回原来的 \(HotKeyAction.screenshot.presetCombo.display)")
        button("⌃⇧1–⌃⇧6", in: shortcuts.view)?.performClick(nil)
        check(HotKeyAction.schemeActions.allSatisfy { Settings.hotKey($0) == $0.combo(in: .control) } && Settings.hotKeyScheme == .control
              && shotField.title == "⌃⇧1" && measureField.title == "⌃⇧6", "一键套用 ⌃⇧1–⌃⇧6：七个一起换（清掉的测量也回来了）")
        button("⌘1–⌘6", in: shortcuts.view)?.performClick(nil)
        check(Settings.hotKeyScheme == .command && Settings.screenshotHotKeyIndex == 0 && shotField.title == "⌘1"
              && HotKeyAction.schemeActions.allSatisfy { shortcuts.resetButtons[$0]?.isEnabled == false }, "一键套用 ⌘1–⌘6：全回到 ⌘1–⌘6 那套")

        // 存法：没单独改过 = 照以前存的"第几个"；按出来和某个预设一样时带上它的说明
        Settings.setHotKey(HotKeyCombo(keyCode: 18, modifiers: [.command]), for: .screenshot)
        check(Settings.hotKey(.screenshot)?.rival?.name == "Snipaste" && Settings.hotKey(.screenshot)?.display == "⌘1",
              "自己按出 ⌘1：还认得它和 Snipaste 抢同一个键")
        Settings.resetHotKey(.screenshot)
        Settings.screenshotHotKeyIndex = 0
        check(Settings.hotKey(.screenshot)?.display == "⌘1", "没在设置窗口里改过：照以前选的那套（你这台 ⌘1–⌘6 一点不变）")
        Settings.setHotKey(HotKeyCombo(keyCode: 2, modifiers: [.control, .option]), for: .screenPen)
        check(Settings.hotKey(.screenPen)?.display == "⌃⌥D", "屏幕画笔也能改（⌃⌥D）")
        Settings.resetHotKey(.screenPen)
        check(Settings.hotKey(.screenPen)?.display == "⌃⇧D", "屏幕画笔恢复默认 ⌃⇧D")

        // 截图、录屏、剪贴板三页：改了马上生效
        let saveBefore = Settings.saveToFile, quickBefore = Settings.screenshotQuickMode
        shot.saveBox.toggleForTest()
        shot.quickBox.toggleForTest()
        shot.colorPopup.selectItem(at: 1)
        shot.colorPicked()
        check(Settings.saveToFile == !saveBefore && Settings.screenshotQuickMode == !quickBefore && !Settings.colorAsHex,
              "截图页：存不存文件、快速模式、取色复制成 RGB，点了马上改")
        check(button("更改…", in: shot.view) != nil && button("在访达中打开", in: shot.view) != nil
              && button("恢复默认", in: shot.view) != nil, "截图页：保存位置能改、能在访达中打开、能恢复默认")
        record.qualityPopup.selectItem(at: 1)
        record.qualityPicked()
        let previewBefore = Settings.recordOpenPreview
        record.previewBox.toggleForTest()
        check(Settings.recordQuality == .hd30 && Settings.recordOpenPreview == !previewBefore && button("更改…", in: record.view) != nil,
              "录屏页：画质、录完打开预览、保存位置")
        clip.reload()
        check(clip.countLabel.stringValue == "3 条，其中收藏 1 条" && clip.clearButton.isEnabled
              && clip.ignoreLabel.stringValue == "\(ClipboardIgnoreList.ids.count) 个", "剪贴板页：历史几条、收藏几条、不记录的软件几个")
        clip.clearButton.performClick(nil)
        check(store.items.count == 1 && store.items.first?.pinned == true && clip.countLabel.stringValue == "1 条，其中收藏 1 条"
              && !clip.clearButton.isEnabled, "剪贴板页：清空历史，收藏的留着")
        let pausedBefore = Settings.clipboardPaused
        clip.pauseBox.toggleForTest()
        button("管理…", in: clip.view)?.performClick(nil)
        check(Settings.clipboardPaused == !pausedBefore && ignores == 1, "剪贴板页：暂停记录、管理不记录的软件")
        settings.window.close()

        restoreDefaults(savedDefaults)
        check(HotKeyAction.allCases.map(Settings.isCustomHotKey) == wasCustom && Settings.saveToFile == saveBefore
              && Settings.clipboardPaused == pausedBefore, "测完设置窗口：快捷键和各项设置都换回测之前的样子")
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

    private static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1,
                              mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: mods, timestamp: 0,
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

/// 屏幕画笔实录检查：MacKit --pen-smoke <结果文件>（台阶 16）
/// 真的录屏幕左上角一小块 2 秒，同时用屏幕画笔在那里画一条红线（不收键盘、不弹别的窗口），
/// 从视频里取一帧看红线在不在；录完删掉视频。要用 open 启动（录屏权限才算在 MacKit 头上）
@MainActor
enum PenSmokeTest {
    static func run(resultPath: String) {
        Task { @MainActor in
            var lines: [String] = []
            var ok = false
            guard let screen = NSScreen.screens.first, let id = screen.displayID else { finish(["没有屏幕"], false, resultPath); return }
            let viewRect = CGRect(x: 40, y: screen.frame.height - 60 - 160, width: 240, height: 160)
            let target = RecordTarget.region(id: id, screenFrame: screen.frame, viewRect: viewRect)
            let pen = ScreenPenSession(region: target.globalFrame)
            pen.begin(takeKeyboard: false)
            pen.editor.document.add(Annotation(tool: .pen, color: .red, size: .thick,
                                               points: [CGPoint(x: 20, y: 80), CGPoint(x: 120, y: 80), CGPoint(x: 220, y: 80)]))
            pen.editor.reloadFromDocument()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-pen-smoke-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("pen.mp4")
            let recorder = ScreenRecorder(url: url)
            do {
                try await recorder.start(target: target, options: RecordOptions(systemAudio: false, microphone: false, quality: .original60),
                                         excluding: [pen.toolbarWindowNumber])
                try? await Task.sleep(for: .seconds(2))
                await recorder.stop()
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
                var red = 0
                if let px = PixelBuffer(image: frame) {
                    for y in stride(from: 0, to: frame.height, by: 2) {
                        for x in stride(from: 0, to: frame.width, by: 2) {
                            let c = px.rgb(x, y)
                            if c.0 > 200 && c.1 < 90 && c.2 < 90 { red += 1 }
                        }
                    }
                }
                lines.append("实录：视频 \(frame.width)×\(frame.height)，画的红线在画面里找到 \(red) 个红点（抽样）")
                ok = red > 60
            } catch {
                lines.append("实录失败：\(error.localizedDescription)")
            }
            pen.close()
            finish(lines, ok, resultPath)
        }
    }

    private static func finish(_ lines: [String], _ ok: Bool, _ path: String) {
        try? (lines + [ok ? "SMOKE OK" : "SMOKE FAILED"]).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }
}
