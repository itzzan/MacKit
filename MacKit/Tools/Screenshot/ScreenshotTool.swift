@preconcurrency import ScreenCaptureKit
import AppKit

/// 截图积木：快捷键 / 菜单 → 冻住屏幕 → 框选或单击窗口 → 标注 → 复制并保存 / 贴图 / 另存
@MainActor
final class ScreenshotTool: ToolModule {
    private(set) var hotKeyRegistered = false
    /// 截图后点 📌 / 按 ⌘2：交给贴图积木（AppDelegate 里接上）
    var onPin: ((SelectionResult) -> Void)?
    /// 截图工具栏上点"识别文字"：交给识别积木（AppDelegate 里接上）
    var onRecognize: ((CGImage) -> Void)?
    /// 工具栏上点"长截图"或菜单里"长截图"选好了框：交给长截图积木（AppDelegate 里接上）
    var onLongShot: ((ScreenRegion) -> Void)?
    /// 工具栏上点"美化"：交给美化积木（AppDelegate 里接上）
    var onBeautify: ((SelectionResult) -> Void)?
    private var hotKeyID: UInt32?
    private var session: SelectionSession?
    private var isPreparing = false
    private(set) var delayed: DelayCountdown?

    func activate() { registerHotKey() }

    func reloadHotKeys() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = HotKeyCenter.shared.register(Settings.screenshotHotKey) { [weak self] in
            self?.startSelection()
        }
        hotKeyRegistered = hotKeyID != nil
    }

    // MARK: 截图流程

    /// delay：从菜单点进来时等菜单收起，免得把菜单也截进去。purpose = .longShot：选好框直接开始长截图
    func startSelection(delay: Double = 0, purpose: SelectionSession.Purpose = .screenshot) {
        guard session == nil, !isPreparing, SelectionSession.active == nil, MeasureSession.active == nil,
              LongShotSession.active == nil else { return }
        guard ScreenPermission.readyToTry() else { return }
        isPreparing = true
        Task { @MainActor in
            defer { self.isPreparing = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let windows = WindowList.currentFrames()
            do {
                let frozen = try await ScreenCapturer.capture()
                guard !frozen.isEmpty else { return }
                let session = SelectionSession(screens: frozen, windowFrames: windows,
                                               quickMode: Settings.screenshotQuickMode, purpose: purpose)
                session.onFinish = { [weak self] outcome in
                    self?.session = nil
                    self?.handle(outcome)
                }
                self.session = session
                session.begin()
            } catch {
                self.handle(error)
            }
        }
    }

    /// 延时截图：屏幕中间倒数，倒数完和 ⌘1 一样冻屏框选。趁这几秒打开要截的菜单、把鼠标放到会出提示的地方
    func startDelayed(seconds: Int) {
        guard delayed == nil, session == nil, !isPreparing, SelectionSession.active == nil, MeasureSession.active == nil,
              LongShotSession.active == nil else { return }
        guard ScreenPermission.readyToTry() else { return }
        let frame = (NSScreen.withMouse ?? NSScreen.main)?.frame ?? .zero
        let countdown = DelayCountdown(seconds: seconds, center: CGPoint(x: frame.midX, y: frame.midY))
        countdown.onFire = { [weak self] in
            self?.delayed = nil
            self?.startSelection(delay: 0.15)        // 等倒数的窗口从屏幕上消失再冻屏
        }
        countdown.onCancel = { [weak self] in
            self?.delayed = nil
            Toast.show("已取消延时截图")
        }
        delayed = countdown
        Log.capture.notice("delayed screenshot in \(seconds)s")
        countdown.start()
    }

    func captureFullScreen() {
        guard ScreenPermission.readyToTry() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
            do {
                guard let frozen = try await ScreenCapturer.capture([screen]).first else { return }
                self.deliver(SelectionResult(image: frozen.image, pointSize: screen.frame.size,
                                             globalFrame: screen.frame))
            } catch {
                self.handle(error)
            }
        }
    }

    /// 截图结束后去哪：复制、贴图、已另存、取消
    private func handle(_ outcome: SelectionOutcome) {
        switch outcome {
        case .copy(let result):
            deliver(result)
        case .pin(let result):
            Log.capture.notice("screenshot pinned \(result.image.width)x\(result.image.height)")
            onPin?(result)
        case .saved(let url):
            Log.capture.notice("saved as \(url.path, privacy: .public)")
            Toast.show("✓ 已保存：\(url.lastPathComponent)")
        case .recognize(let result):
            onRecognize?(result.image)
        case .longShot(let region):
            onLongShot?(region)
        case .beautify(let result):
            onBeautify?(result)
        case .record, .cancelled:
            break
        }
    }

    private func deliver(_ result: SelectionResult) {
        guard let png = ImageOutput.pngData(of: result.image, pointSize: result.pointSize) else {
            Toast.show("截图失败：图片编码出错")
            return
        }
        ImageOutput.copyToClipboard(result.image, pointSize: result.pointSize, png: png)
        CaptureHistory.record(image: result.image, pointSize: result.pointSize,
                              globalFrame: result.globalFrame, pasteboard: .general)
        var message = "✓ 已复制到剪贴板"
        if Settings.saveToFile {
            do {
                let url = try ImageOutput.save(png: png, to: Settings.saveFolder)
                message += "，已保存"
                Log.capture.notice("saved \(url.path, privacy: .public)")
            } catch {
                message += "，但保存失败：\(error.localizedDescription)"
                Log.capture.error("save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Toast.show("\(message)　\(result.image.width)×\(result.image.height)")
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        Log.capture.error("capture failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
        let declined = ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
        if declined || !ScreenPermission.isGranted {
            ScreenPermission.showGuide()
        } else {
            Toast.show("截图失败：\(ns.localizedDescription)", seconds: 3)
        }
    }

    // MARK: 菜单

    func menuItems() -> [NSMenuItem] {
        let combo = Settings.screenshotHotKey
        var items: [NSMenuItem] = []

        items.append(ActionMenuItem("截图（框选区域 / 单击选窗口）",
                                    key: hotKeyRegistered ? combo.menuKey : "",
                                    modifiers: combo.menuModifiers) { [weak self] in
            self?.startSelection(delay: 0.2)
        })
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo.display) 没注册上，可能被别的软件占用，换一个试试"))
        } else if let rival = combo.runningRival {
            items.append(.info("⚠︎ \(rival) 开着，它也用 \(combo.display)，按一下会弹出两个截图"))
            items.append(.info("　 先退出 \(rival)，或在下面的「截图快捷键」里换一个"))
        }
        items.append(ActionMenuItem("截取整个屏幕") { [weak self] in self?.captureFullScreen() })
        items.append(ActionMenuItem("长截图（框选后往下滚，拼成一张长图）") { [weak self] in
            self?.startSelection(delay: 0.2, purpose: .longShot)
        })
        let delayMenu = NSMenu()
        for seconds in [3, 5, 10] {
            delayMenu.addItem(ActionMenuItem("\(seconds) 秒后截图") { [weak self] in self?.startDelayed(seconds: seconds) })
        }
        delayMenu.addItem(.separator())
        delayMenu.addItem(.info("趁倒数打开要截的菜单、把鼠标放到会出提示的地方"))
        delayMenu.addItem(.info("倒数时按 Esc 取消"))
        let delayItem = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        items.append(delayItem)
        if !Settings.recentColors.isEmpty { items.append(RecentColors.menuItem()) }
        return items
    }

    func settingsItems() -> [NSMenuItem] {
        let combo = Settings.screenshotHotKey
        var items: [NSMenuItem] = []
        let colorMenu = NSMenu()
        let hex = ActionMenuItem("HEX，比如 #FF3B30") { Settings.colorAsHex = true }
        hex.state = Settings.colorAsHex ? .on : .off
        let rgb = ActionMenuItem("RGB，比如 255, 59, 48") { Settings.colorAsHex = false }
        rgb.state = Settings.colorAsHex ? .off : .on
        colorMenu.addItem(hex)
        colorMenu.addItem(rgb)
        let colorItem = NSMenuItem(title: "截图时按 C 复制颜色：\(Settings.colorAsHex ? "HEX" : "RGB")", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        items.append(colorItem)
        let quick = ActionMenuItem("快速模式：松手直接复制，不出标注工具栏") { Settings.screenshotQuickMode.toggle() }
        quick.state = Settings.screenshotQuickMode ? .on : .off
        items.append(quick)

        let hotKeyMenu = NSMenu()
        for (index, preset) in HotKeyPresets.screenshot.enumerated() {
            let item = ActionMenuItem("\(preset.display)　\(preset.note)") { [weak self] in
                Settings.screenshotHotKeyIndex = index
                self?.registerHotKey()
            }
            item.state = index == Settings.screenshotHotKeyIndex ? .on : .off
            hotKeyMenu.addItem(item)
        }
        let hotKeyItem = NSMenuItem(title: "截图快捷键：\(combo.display)", action: nil, keyEquivalent: "")
        hotKeyItem.submenu = hotKeyMenu
        items.append(hotKeyItem)

        let saveMenu = NSMenu()
        let toggle = ActionMenuItem("截图时同时存成文件") { Settings.saveToFile.toggle() }
        toggle.state = Settings.saveToFile ? .on : .off
        saveMenu.addItem(toggle)
        saveMenu.addItem(.info("位置：" + (Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath))
        saveMenu.addItem(ActionMenuItem("在访达中打开") {
            let folder = Settings.saveFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        })
        saveMenu.addItem(ActionMenuItem("更改位置…") { [weak self] in self?.chooseFolder() })
        if Settings.saveFolder != Settings.defaultSaveFolder {
            saveMenu.addItem(ActionMenuItem("恢复默认（图片/MacKit）") { Settings.saveFolder = Settings.defaultSaveFolder })
        }
        let saveItem = NSMenuItem(title: "截图保存位置", action: nil, keyEquivalent: "")
        saveItem.submenu = saveMenu
        items.append(saveItem)
        return items
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "就存这里"
        panel.directoryURL = Settings.saveFolder
        panel.begin { response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { Settings.saveFolder = url }
            }
        }
    }
}

/// 延时截图的倒数：屏幕中间 3、2、1，倒数时按 Esc 取消（你在别的软件里，所以 Esc 临时注册成全局快捷键）
@MainActor
final class DelayCountdown {
    var onFire: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var remaining: Int
    let window: CountdownWindow?
    private let interval: TimeInterval
    private var timer: Timer?
    private var escID: UInt32?
    private(set) var isRunning = false

    /// showWindow = false：不显示窗口、不注册 Esc（自检用）；interval：每一下多久（自检里调快）
    init(seconds: Int, center: CGPoint, showWindow: Bool = true, interval: TimeInterval = 1) {
        remaining = max(seconds, 1)
        window = showWindow ? CountdownWindow(center: center, hint: "Esc 取消") : nil
        self.interval = interval
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if window != nil {
            let esc = HotKeyCombo(keyCode: 53, carbonModifiers: 0, display: "Esc", menuKey: "", menuModifiers: [], note: "")
            escID = HotKeyCenter.shared.register(esc) { [weak self] in self?.cancel() }
        }
        window?.show(remaining)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        remaining -= 1
        if remaining > 0 {
            window?.show(remaining)
            return
        }
        stop()
        onFire?()
    }

    func cancel() {
        guard isRunning else { return }
        stop()
        Log.capture.notice("delayed screenshot cancelled")
        onCancel?()
    }

    private func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let escID { HotKeyCenter.shared.unregister(escID) }
        escID = nil
        window?.close()
    }
}

/// 最近取过的颜色（台阶 15）：⌘1 截图时按 C 取的，存最近 20 个（只存颜色数字，不存截图）
@MainActor
enum RecentColors {
    static func record(_ r: Int, _ g: Int, _ b: Int) {
        Settings.recentColors = ColorHistory.adding(ColorHistory.pack(r, g, b), to: Settings.recentColors)
    }

    /// 菜单"最近的颜色"：小色块 + HEX，点一下复制；按住 ⌥ 显示 RGB，点了复制 RGB
    static func menuItem() -> NSMenuItem {
        let sub = NSMenu()
        for value in Settings.recentColors {
            let (r, g, b) = ColorHistory.unpack(value)
            let hex = ColorText.hex(r, g, b), rgb = ColorText.rgb(r, g, b)
            let main = ActionMenuItem(hex) { copy(hex) }
            main.image = swatch(r, g, b)
            let alt = ActionMenuItem(rgb, modifiers: .option) { copy(rgb) }
            alt.image = swatch(r, g, b)
            alt.isAlternate = true
            sub.addItem(main)
            sub.addItem(alt)
        }
        sub.addItem(.separator())
        sub.addItem(.info("点一下复制 HEX；按住 ⌥ 换成 RGB"))
        sub.addItem(ActionMenuItem("清空") { Settings.recentColors = [] })
        let item = NSMenuItem(title: "最近的颜色（\(Settings.recentColors.count) 个）", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("✓ 已复制颜色 \(text)")
    }

    /// 菜单里的小色块（圆角方块，加一圈细边，白色也看得见）
    static func swatch(_ r: Int, _ g: Int, _ b: Int) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
