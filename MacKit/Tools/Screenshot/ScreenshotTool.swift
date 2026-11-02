@preconcurrency import ScreenCaptureKit
import AppKit

/// 截图积木：快捷键 / 菜单 → 冻住屏幕 → 框选或单击窗口 → 复制到剪贴板 + 存文件
@MainActor
final class ScreenshotTool: ToolModule {
    private(set) var hotKeyRegistered = false
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

    /// delay：从菜单点进来时等菜单收起，免得把菜单也截进去
    func startSelection(delay: Double = 0) {
        guard session == nil, !isPreparing else { return }
        guard ScreenPermission.readyToTry() else { return }
        isPreparing = true
        Task { @MainActor in
            defer { self.isPreparing = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let windows = WindowList.currentFrames()
            do {
                let frozen = try await ScreenCapturer.capture()
                guard !frozen.isEmpty else { return }
                let session = SelectionSession(screens: frozen, windowFrames: windows)
                session.onFinish = { [weak self] result in
                    self?.session = nil
                    if let result { self?.deliver(result) }
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
        if panel.runModal() == .OK, let url = panel.url { Settings.saveFolder = url }
    }
}
