import AppKit

/// 剪贴板积木：在后台记下复制过的东西；⌘3 弹出历史，搜索、粘贴、置顶、删除、钉成贴图
@MainActor
final class ClipboardTool: ToolModule {
    let store: ClipboardStore
    let watcher: ClipboardWatcher
    /// 选中一条按 ⌘2：交给贴图积木（AppDelegate 里接上）。参数是放着这条内容的私有剪贴板
    var onPin: ((NSPasteboard) -> Void)?
    private(set) var hotKeyRegistered = false
    private var hotKeyID: UInt32?
    private var panel: ClipboardPanel?

    init(store: ClipboardStore? = nil, pasteboard: NSPasteboard? = nil) {
        self.store = store ?? ClipboardStore()
        self.watcher = ClipboardWatcher(pasteboard: pasteboard ?? .general)
    }

    func activate() {
        registerHotKey()
        // 自检时不读你真实的历史、不盯你的剪贴板
        guard !CommandLine.arguments.contains("--selftest") else { return }
        store.load()
        watcher.isPaused = { Settings.clipboardPaused }
        watcher.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let item = self.store.add(snapshot)
            if item.kind == .image, item.copyCount == 1 { self.recognizeText(in: item) }
        }
        watcher.start()
    }

    /// 新复制进来的图片：后台识别里面的字，以后能搜到（台阶 7）
    func recognizeText(in item: ClipboardItem) {
        guard let entry = item.pasteboardItems.first?.first(where: { NSBitmapImageRep.imageTypes.contains($0.type) }),
              let data = store.data(of: entry), let image = NSBitmapImageRep(data: data)?.cgImage else { return }
        let id = item.id
        Task { @MainActor in
            let result = await TextRecognizer.recognize(image)
            if !result.lines.isEmpty { self.store.setRecognizedText(id, result.text) }
        }
    }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = HotKeyCenter.shared.register(Settings.clipboardHotKey) { [weak self] in self?.togglePanel() }
        hotKeyRegistered = hotKeyID != nil
    }

    // MARK: 小窗口

    func togglePanel() {
        if let open = ClipboardPanel.visible {
            open.close(returnFocus: true)
            return
        }
        guard SelectionSession.active == nil, MeasureSession.active == nil else { return }    // 截图、测量中不弹
        let p = makePanel()
        panel = p
        p.show(near: NSEvent.mouseLocation)
    }

    /// 只造不显示（自检也用）
    func makePanel() -> ClipboardPanel {
        let p = ClipboardPanel(store: store)
        p.onPaste = { [weak self] item, plain in self?.paste(item, plainText: plain) }
        p.onPin = { [weak self] item in self?.pin(item) }
        return p
    }

    // MARK: 粘贴、贴图

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        store.touch(item.id)
        guard ClipboardPaster.write(item, plainText: plainText, store: store, to: .general) else {
            Toast.show("粘贴失败：内容放不回剪贴板", seconds: 3)
            return
        }
        if ClipboardPaster.canAutoPaste {
            ClipboardPaster.pasteIntoFrontApp()
        } else {
            Toast.show("✓ 已复制，按 ⌘V 粘贴。想回车直接粘贴：菜单栏 MacKit →「自动粘贴」去开权限", seconds: 4)
            if !Settings.askedAccessibility {
                Settings.askedAccessibility = true
                ClipboardPaster.requestAccessibility()               // 第一次：让系统弹授权提示
            }
        }
    }

    private func pin(_ item: ClipboardItem) {
        let pb = NSPasteboard(name: NSPasteboard.Name("local.mackit.clipboard.pin.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        guard ClipboardPaster.write(item, plainText: false, store: store, to: pb) else { return }
        onPin?(pb)
    }

    // MARK: 菜单

    func menuItems() -> [NSMenuItem] {
        let combo = Settings.clipboardHotKey
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("剪贴板历史（\(store.items.count) 条）",
                                    key: hotKeyRegistered ? combo.menuKey : "",
                                    modifiers: combo.menuModifiers) { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.15))           // 等菜单收起
                self?.togglePanel()
            }
        })
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo.display) 没注册上，可能被别的软件占用，换一个试试"))
        }
        // 暂停着、自动粘贴没开：第一层也提醒一下
        if Settings.clipboardPaused {
            items.append(ActionMenuItem("⏸ 暂停记录中（点这里恢复）") { Settings.clipboardPaused = false })
        }
        if !ClipboardPaster.canAutoPaste {
            items.append(ActionMenuItem("自动粘贴：未开启（点这里去开「辅助功能」权限）") {
                ClipboardPaster.requestAccessibility()
                ClipboardPaster.openAccessibilitySettings()
            })
        }
        return items
    }

    func settingsItems() -> [NSMenuItem] {
        let combo = Settings.clipboardHotKey
        var items: [NSMenuItem] = []
        let pause = ActionMenuItem("暂停记录") { Settings.clipboardPaused.toggle() }
        pause.state = Settings.clipboardPaused ? .on : .off
        items.append(pause)
        if store.unpinnedCount > 0 {
            items.append(ActionMenuItem("清空历史（保留置顶的）") { [weak self] in self?.store.clearUnpinned() })
        }
        if ClipboardPaster.canAutoPaste { items.append(.info("自动粘贴：已开启")) }

        let keyMenu = NSMenu()
        for (index, preset) in ClipboardHotKeyPresets.all.enumerated() {
            let item = ActionMenuItem("\(preset.display)　\(preset.note)") { [weak self] in
                Settings.clipboardHotKeyIndex = index
                self?.registerHotKey()
            }
            item.state = index == Settings.clipboardHotKeyIndex ? .on : .off
            keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "剪贴板快捷键：\(combo.display)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
        return items
    }
}
