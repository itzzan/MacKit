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
    private var hotKeyID: UInt32?
    private var session: SelectionSession?
    private var isPreparing = false

    func activate() { registerHotKey() }

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
