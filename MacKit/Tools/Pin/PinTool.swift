import AppKit

/// 贴图积木：⌘2 把剪贴板里的图片或文字钉在屏幕上，⇧⌘2 隐藏/显示全部
@MainActor
final class PinTool: ToolModule {
    private(set) var pins: [PinWindow] = []
    private(set) var hotKeysRegistered = false
    private var hotKeyIDs: [UInt32] = []
    private var hidden = false
    /// 贴图右键"识别文字"：交给识别积木（AppDelegate 里接上）
    var onRecognize: ((CGImage) -> Void)?
    /// 贴图右键"美化…"：交给美化积木（AppDelegate 里接上）
    var onBeautify: ((CGImage, CGSize) -> Void)?

    /// 关掉的贴图（台阶 13）：只在内存里记最近 20 张，退出 MacKit 就清空（拍板：不在硬盘上留截图）
    struct ClosedPin {
        let image: CGImage
        let rendered: CGImage
        let size: NSSize
        let checkpoint: AnnotationDocument.Checkpoint
        let frame: CGRect
        let scale: CGFloat
        let alpha: CGFloat
        let closedAt: Date
    }
    static let closedLimit = 20
    private(set) var closed: [ClosedPin] = []              // 最新的在前面

    func activate() { registerHotKeys() }

    func reloadHotKeys() { registerHotKeys() }

    private func registerHotKeys() {
        for id in hotKeyIDs { HotKeyCenter.shared.unregister(id) }
        let keys = Settings.pinHotKeys
        let pinID = HotKeyCenter.shared.register(keys.pin) { [weak self] in self?.pinFromClipboard() }
        let toggleID = HotKeyCenter.shared.register(keys.toggle) { [weak self] in self?.toggleAll() }
        hotKeyIDs = [pinID, toggleID].compactMap { $0 }
        hotKeysRegistered = pinID != nil && toggleID != nil
    }

    // MARK: 贴图

    func pinFromClipboard() {
        // 正在截图标注：⌘2 = 把这次截图（带标注）钉在原位置
        if let session = SelectionSession.active {
            if session.isEditing { session.finishPin() }
            return                      // 还在框选时不贴，免得贴图被冻住的画面挡住
        }
        // 剪贴板历史开着：⌘2 = 把选中的那条钉成贴图
        if let panel = ClipboardPanel.visible {
            panel.requestPin()
            return
        }
        guard let content = PinContentReader.read(.general) else {
            Toast.show("剪贴板里没有图片或文字")
            return
        }
        show(makePin(for: content, mouse: NSEvent.mouseLocation))
    }

    /// 从剪贴板历史贴：读那块私有剪贴板里的内容
    func pinFromPasteboard(_ pb: NSPasteboard) {
        guard let content = PinContentReader.read(pb) else {
            Toast.show("这条内容贴不出来（不是图片也不是文字）")
            return
        }
        show(makePin(for: content, mouse: NSEvent.mouseLocation))
    }

    /// 截图编辑完直接贴：钉在截取的原位置
    func pin(_ result: SelectionResult) {
        show(PinWindow(image: result.image, pointSize: result.pointSize, frame: result.globalFrame, scale: 1))
    }

    /// 长截图拼好后点"钉成贴图"：缩到屏幕放得下，放在鼠标旁边
    func pinImage(_ image: CGImage, pointSize: NSSize) {
        show(makePin(for: .image(image, pointSize: pointSize), mouse: NSEvent.mouseLocation))
    }

    /// 只造窗口不显示（自检也用它）
    func makePin(for content: PinContent, mouse: CGPoint) -> PinWindow? {
        let visible = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        switch content {
        case .original(let record):
            Log.app.notice("pin: last screenshot at its original place")
            return PinWindow(image: record.image, pointSize: record.pointSize, frame: record.globalFrame, scale: 1)
        case .image(let image, let size):
            Log.app.notice("pin: image from clipboard \(image.width)x\(image.height)")
            let place = PinGeometry.initialPlacement(size: size, around: mouse, visible: visible)
            return PinWindow(image: image, pointSize: size, frame: place.frame, scale: place.scale)
        case .text(let text):
            Log.app.notice("pin: text card, \(text.count) chars")
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let card = TextCard.render(text, scale: scale) else { return nil }
            let place = PinGeometry.initialPlacement(size: card.pointSize, around: mouse, visible: visible)
            return PinWindow(image: card.image, pointSize: card.pointSize, frame: place.frame, scale: place.scale)
        }
    }

    private func show(_ pin: PinWindow?) {
        guard let pin else {
            Toast.show("贴图失败")
            return
        }
        pin.onClosed = { [weak self] gone in
            self?.pins.removeAll { $0 === gone }
            self?.remember(gone)
        }
        pin.onCloseAll = { [weak self] in self?.closeAll() }
        pin.onRecognize = { [weak self] image in self?.onRecognize?(image) }
        pin.onBeautify = { [weak self] image, size in self?.onBeautify?(image, size) }
        if hidden { showAll() }
        pins.append(pin)
        NSApp.unhideWithoutActivation()
        pin.orderFrontRegardless()          // 不抢焦点：贴完可以接着在原来的软件里打字
    }

    func toggleAll() {
        if pins.isEmpty {
            Toast.show("还没有贴图")
        } else if hidden {
            showAll()
        } else {
            for pin in pins { pin.orderOut(nil) }
            hidden = true
        }
    }

    private func showAll() {
        NSApp.unhideWithoutActivation()
        for pin in pins { pin.orderFrontRegardless() }
        hidden = false
    }

    func closeAll() {
        let all = pins
        pins.removeAll()
        hidden = false
        for pin in all {
            pin.onClosed = nil
            if pin.isCropping { pin.endCrop(nil) }
            pin.orderOut(nil)
            remember(pin)
        }
    }

    // MARK: 找回关掉的贴图

    func remember(_ pin: PinWindow) {
        if pin.isCropping { pin.endCrop(nil) }
        closed.insert(ClosedPin(image: pin.originalImage, rendered: pin.image, size: pin.basePointSize,
                                checkpoint: pin.document.checkpoint(), frame: pin.frame, scale: pin.scale,
                                alpha: pin.alphaValue, closedAt: Date()), at: 0)
        if closed.count > Self.closedLimit { closed.removeLast(closed.count - Self.closedLimit) }
    }

    /// 贴回原来的位置、原来的大小，标注也在。present = false 只给自检用
    @discardableResult
    func reopen(at index: Int, present: Bool = true) -> PinWindow? {
        guard closed.indices.contains(index) else { return nil }
        let record = closed.remove(at: index)
        let pin = PinWindow(image: record.image, pointSize: record.size, frame: record.frame, scale: record.scale)
        pin.restoreAnnotations(record.checkpoint)
        pin.alphaValue = record.alpha
        if present {
            show(pin)
        } else {
            pin.onClosed = { [weak self] gone in
                self?.pins.removeAll { $0 === gone }
                self?.remember(gone)
            }
            pins.append(pin)
        }
        Log.app.notice("pin: reopened a closed pin")
        return pin
    }

    func clearClosed() { closed.removeAll() }

    private func closedMenu() -> NSMenuItem {
        let sub = NSMenu()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for (i, record) in closed.enumerated() {
            let item = ActionMenuItem("\(formatter.string(from: record.closedAt)) 关掉的　\(Int(record.size.width))×\(Int(record.size.height))") {
                [weak self] in self?.reopen(at: i)
            }
            let thumb = NSImage(cgImage: record.rendered, size: Self.thumbSize(record.size))
            item.image = thumb
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(ActionMenuItem("清空这个列表") { [weak self] in self?.clearClosed() })
        sub.addItem(.info("只记这次打开 MacKit 以来的，退出就清空"))
        let item = NSMenuItem(title: "找回关掉的贴图（\(closed.count) 张）", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// 菜单里的小图：最大 48×32 点，等比例
    static func thumbSize(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 32, height: 32) }
        let k = min(48 / size.width, 32 / size.height, 1)
        return NSSize(width: max((size.width * k).rounded(), 1), height: max((size.height * k).rounded(), 1))
    }

    private func releaseClickThrough() {
        for pin in pins where pin.isClickThrough { pin.setClickThrough(false) }
    }

    // MARK: 菜单

    func menuItems() -> [NSMenuItem] {
        let keys = Settings.pinHotKeys
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("贴图（剪贴板里的图片或文字）",
                                    key: hotKeysRegistered ? keys.pin.menuKey : "",
                                    modifiers: keys.pin.menuModifiers) { [weak self] in
            self?.pinFromClipboard()
        })
        if !hotKeysRegistered {
            items.append(.info("⚠︎ 快捷键 \(keys.pin.display) 没注册上，可能被别的软件占用，换一个试试"))
        } else if let rival = keys.pin.runningRival {
            items.append(.info("⚠︎ \(rival) 开着，它也用 \(keys.pin.display)，按一下会贴出两张"))
        }

        if !pins.isEmpty {
            // 已经贴了几张：管理的操作收进一个子菜单，免得菜单变长
            let manage = NSMenu()
            manage.addItem(ActionMenuItem(hidden ? "全部显示" : "全部隐藏",
                                          key: hotKeysRegistered ? keys.toggle.menuKey : "",
                                          modifiers: keys.toggle.menuModifiers) { [weak self] in
                self?.toggleAll()
            })
            if pins.contains(where: { $0.isClickThrough }) {
                manage.addItem(ActionMenuItem("取消所有穿透") { [weak self] in self?.releaseClickThrough() })
            }
            manage.addItem(ActionMenuItem("关闭全部贴图") { [weak self] in self?.closeAll() })
            let manageItem = NSMenuItem(title: "已贴 \(pins.count) 张\(hidden ? "（已隐藏）" : "")", action: nil, keyEquivalent: "")
            manageItem.submenu = manage
            items.append(manageItem)
        }
        if !closed.isEmpty { items.append(closedMenu()) }
        return items
    }

    func settingsItems() -> [NSMenuItem] {
        let keys = Settings.pinHotKeys
        var items: [NSMenuItem] = []
        let keyMenu = NSMenu()
        for (index, preset) in PinHotKeyPresets.all.enumerated() {
            let item = ActionMenuItem("\(preset.pin.display) 贴图，\(preset.toggle.display) 隐藏/显示　\(preset.pin.note)") { [weak self] in
                Settings.pinHotKeyIndex = index
                self?.registerHotKeys()
            }
            item.state = index == Settings.pinHotKeyIndex ? .on : .off
            keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "贴图快捷键：\(keys.pin.display) / \(keys.toggle.display)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
        return items
    }
}
