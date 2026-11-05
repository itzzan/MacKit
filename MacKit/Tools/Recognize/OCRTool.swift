import AppKit

/// 识别文字积木：⌘5 框选 → 识别 → 复制到剪贴板并弹出结果窗口。截图工具栏、贴图右键也走这里
@MainActor
final class OCRTool: ToolModule {
    private(set) var hotKeyRegistered = false
    private var hotKeyID: UInt32?
    private var session: SelectionSession?
    private var isPreparing = false
    private var windows: [OCRResultWindow] = []

    func activate() { registerHotKey() }

    func reloadHotKeys() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = Settings.hotKey(.ocr).flatMap { HotKeyCenter.shared.register($0) { [weak self] in self?.choose() } }
        hotKeyRegistered = Settings.hotKey(.ocr) == nil || hotKeyID != nil
    }

    /// translate = true：菜单里"识别并翻译"，框完直接出译文（台阶 15）
    func choose(delay: Double = 0, translate: Bool = false) {
        guard session == nil, !isPreparing, SelectionSession.active == nil, MeasureSession.active == nil else { return }
        guard ScreenPermission.readyToTry() else { return }
        isPreparing = true
        Task { @MainActor in
            defer { self.isPreparing = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let windows = WindowList.current()
            do {
                let frozen = try await ScreenCapturer.capture()
                guard !frozen.isEmpty else { return }
                let s = SelectionSession(screens: frozen, windowFrames: windows.map(\.frame), quickMode: false,
                                         windowIDs: windows.map(\.id), purpose: .recognize)
                s.onFinish = { [weak self] outcome in
                    self?.session = nil
                    if case .recognize(let result) = outcome { self?.recognize(result.image, translate: translate) }
                }
                self.session = s
                s.begin()
            } catch {
                Log.capture.error("ocr: capture failed \(error.localizedDescription, privacy: .public)")
                ScreenPermission.showGuide()
            }
        }
    }

    /// 识别一张图（截图工具栏、贴图右键也调这里）
    func recognize(_ image: CGImage, translate: Bool = false) {
        Toast.show("正在识别文字…", seconds: 10)
        Task { @MainActor in
            let result = await TextRecognizer.recognize(image)
            Log.capture.notice("ocr: \(result.lines.count) lines, \(result.codes.count) codes")
            let copied = !result.lines.isEmpty ? result.text : result.codes.first
            if let copied {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copied, forType: .string)
                Toast.show("✓ 已复制 \(copied.count) 个字", seconds: 1.5)
            } else {
                Toast.show("这块里没认出文字", seconds: 2)
            }
            let w = self.showResult(result)
            if translate, !result.text.isEmpty { w.translate() }
        }
    }

    @discardableResult
    func showResult(_ result: OCRResult, present: Bool = true) -> OCRResultWindow {
        let w = OCRResultWindow(result: result)
        w.onClose = { [weak self, weak w] in
            self?.windows.removeAll { $0 === w }
            if self?.windows.isEmpty == true, NSApp.isActive, NSApp.modalWindow == nil { NSApp.hide(nil) }
        }
        windows.append(w)
        w.show(present: present)
        return w
    }

    func menuItems() -> [NSMenuItem] {
        let combo = Settings.hotKey(.ocr)
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("识别文字（框选）", key: hotKeyRegistered ? (combo?.menuKey ?? "") : "",
                                    modifiers: combo?.menuModifiers ?? []) { [weak self] in self?.choose(delay: 0.2) })
        items.append(ActionMenuItem("识别并翻译（框选）") { [weak self] in self?.choose(delay: 0.2, translate: true) })
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo?.display ?? "") 没注册上，可能被别的软件占用，在「设置 → 快捷键」里换一个"))
        }
        return items
    }

}
