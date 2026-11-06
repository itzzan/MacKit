import AppKit
import ApplicationServices
import AVFoundation

/// 设置窗口要用到的外面的东西（AppDelegate 接上）
@MainActor
struct SettingsHooks {
    var reloadHotKeys: () -> Void = {}
    var showWelcome: () -> Void = {}
    var clearClipboard: () -> Void = {}
    var clipboardCounts: () -> (all: Int, favorites: Int) = { (0, 0) }
    var openIgnoreList: () -> Void = {}
    var updateChecker = UpdateChecker()
    /// 自检时 true：开机启动只看状态、不真的去加登录项
    var dryRun = false
}

/// 设置窗口（台阶 17）：上面一排图标分页——通用、快捷键、截图、录屏、剪贴板；改了马上生效
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Pane: Int, CaseIterable {
        case general, shortcuts, screenshot, record, clipboard

        var title: String { ["通用", "快捷键", "截图", "录屏", "剪贴板"][rawValue] }
        var symbol: String { ["gearshape", "keyboard", "camera.viewfinder", "record.circle", "doc.on.clipboard"][rawValue] }
    }

    let window: NSWindow
    let tabs = NSTabViewController()
    let hooks: SettingsHooks
    private(set) var panes: [Pane: SettingsPane] = [:]
    var onClose: (() -> Void)?

    init(hooks: SettingsHooks) {
        self.hooks = hooks
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 420),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        tabs.tabStyle = .toolbar
        for pane in Pane.allCases {
            let vc: SettingsPane = switch pane {
            case .general: GeneralPane(hooks: hooks)
            case .shortcuts: ShortcutsPane(hooks: hooks)
            case .screenshot: ScreenshotPane(hooks: hooks)
            case .record: RecordPane(hooks: hooks)
            case .clipboard: ClipboardPane(hooks: hooks)
            }
            vc.hostWindow = window
            panes[pane] = vc
            let item = NSTabViewItem(viewController: vc)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.title = "MacKit 设置"
    }

    /// pane = nil：停在上次那一页
    func show(_ pane: Pane? = nil) {
        if let pane { select(pane) } else if let current = Pane(rawValue: tabs.selectedTabViewItemIndex) { panes[current]?.reload() }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ pane: Pane) {
        tabs.selectedTabViewItemIndex = pane.rawValue
        panes[pane]?.reload()
    }

    /// 窗口不在前面了：正在录的快捷键算放弃
    func windowDidResignKey(_ notification: Notification) {
        (panes[.shortcuts] as? ShortcutsPane)?.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        (panes[.shortcuts] as? ShortcutsPane)?.stopRecording()
        onClose?()
        // 焦点还给原来的软件；还开着别的普通窗口（欢迎、识别结果…）就不藏，贴图、录制小条本来就不跟着藏
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.canHide && $0.level == .normal }
        if NSApp.isActive, NSApp.modalWindow == nil, others.isEmpty { NSApp.hide(nil) }
    }
}

/// 每一页的底：一张"左边名字、右边设置"的表
@MainActor
class SettingsPane: NSViewController {
    let hooks: SettingsHooks
    weak var hostWindow: NSWindow?
    let grid = NSGridView()

    init(hooks: SettingsHooks) {
        self.hooks = hooks
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        build()
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),     // 每页多高由内容定，窗口跟着变
            container.widthAnchor.constraint(equalToConstant: 620),
        ])
        view = container
        reload()
        preferredContentSize = container.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// 子类在这里往表里加行
    func build() {}
    /// 子类在这里把控件换成现在的设置
    func reload() {}

    func row(_ title: String, _ views: [NSView]) {
        let label = NSTextField(labelWithString: title.isEmpty ? "" : title + "：")
        let right = views.count == 1 ? views[0] : hstack(views)
        grid.addRow(with: [label, right])
    }

    func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .firstBaseline
        return s
    }

    func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        return s
    }

    func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = Theme.small()
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 440
        return t
    }

    func checkbox(_ title: String, _ handler: @escaping @MainActor (Bool) -> Void) -> ClosureCheckbox {
        ClosureCheckbox(title: title, handler: handler)
    }

    /// 保存位置那一行：路径 + 更改… + 在访达中打开 + 恢复默认
    func folderRow(_ title: String, get: @escaping () -> URL, set: @escaping (URL) -> Void, defaultURL: URL) -> NSTextField {
        let path = NSTextField(labelWithString: "")
        path.lineBreakMode = .byTruncatingMiddle
        path.textColor = .secondaryLabelColor
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        let change = ClosureButton(title: "更改…") { [weak self, weak path] in
            guard let self, let window = self.hostWindow else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "就存这里"
            panel.directoryURL = get()
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    if response == .OK, let url = panel.url { set(url) }
                    path?.stringValue = (get().path as NSString).abbreviatingWithTildeInPath
                }
            }
        }
        let open = ClosureButton(title: "在访达中打开") {
            try? FileManager.default.createDirectory(at: get(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(get())
        }
        let reset = ClosureButton(title: "恢复默认") { [weak path] in
            set(defaultURL)
            path?.stringValue = (get().path as NSString).abbreviatingWithTildeInPath
        }
        row(title, [path, change, open, reset])
        return path
    }
}

/// 带闭包的勾选框
@MainActor
final class ClosureCheckbox: NSButton {
    /// 点了之后做什么（建好以后也能换）
    var handler: @MainActor (Bool) -> Void

    init(title: String, handler: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.handler = handler
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    @objc private func fire() { handler(state == .on) }

    /// 自检用：像点了一下
    func toggleForTest() {
        state = state == .on ? .off : .on
        fire()
    }
}

// MARK: 通用

@MainActor
final class GeneralPane: SettingsPane {
    let launchBox = ClosureCheckbox(title: "开机自动启动 MacKit")
    let launchStatus = NSTextField(labelWithString: "")
    private(set) var approveButton: ClosureButton!
    let updateLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var updateButton: ClosureButton!
    private(set) var downloadButton: ClosureButton!
    private var downloadPage: URL?
    private(set) var permissionLabels: [String: NSTextField] = [:]
    private(set) var permissionButtons: [String: ClosureButton] = [:]

    override func build() {
        launchBox.handler = { [weak self] _ in self?.launchToggled() }
        launchStatus.font = Theme.small()
        launchStatus.textColor = .secondaryLabelColor
        approveButton = ClosureButton(title: "去系统设置里同意") { LaunchAtLogin.openSystemSettings() }
        row("启动", [vstack([launchBox, hstack([launchStatus, approveButton])])])

        updateButton = ClosureButton(title: "检查更新") { [weak self] in self?.checkUpdate() }
        downloadButton = ClosureButton(title: "去下载") { [weak self] in
            if let page = self?.downloadPage { NSWorkspace.shared.open(page) }
        }
        downloadButton.isHidden = true
        updateLabel.font = Theme.small()
        updateLabel.textColor = .secondaryLabelColor
        updateLabel.preferredMaxLayoutWidth = 420
        updateLabel.stringValue = "点一下才去问 GitHub，平时 MacKit 不联网；你现在是 \(AppInfo.version)"
        row("更新", [vstack([hstack([updateButton, downloadButton]), updateLabel])])

        for (key, name) in [("screen", "屏幕录制"), ("access", "辅助功能"), ("mic", "麦克风"), ("camera", "摄像头")] {
            let label = NSTextField(labelWithString: "")
            permissionLabels[key] = label
            let go = ClosureButton(title: "去打开") { Self.openPermission(key) }
            permissionButtons[key] = go
            row(key == "screen" ? "权限" : "", [hstack([NSTextField(labelWithString: name), label, go])])
        }
        row("", [note("屏幕录制：截图、录屏必须；辅助功能：回车自动粘贴、长截图自动滚动、连续粘贴；麦克风、摄像头：录屏时开了才要")])
        row("帮助", [ClosureButton(title: "再看一次欢迎窗口") { [weak self] in self?.hooks.showWelcome() }])
    }

    override func reload() {
        launchBox.isOn = LaunchAtLogin.isOn
        launchStatus.stringValue = LaunchAtLogin.statusText
        approveButton?.isHidden = !LaunchAtLogin.needsApproval
        for (key, label) in permissionLabels {
            label.stringValue = Self.isGranted(key) ? "已开启 ✓" : "未开启"
            label.textColor = Self.isGranted(key) ? .secondaryLabelColor : Theme.warning
            permissionButtons[key]?.isHidden = Self.isGranted(key)            // 开好了就不用"去打开"
        }
    }

    private func launchToggled() {
        guard !hooks.dryRun else { return }
        do {
            try LaunchAtLogin.set(launchBox.isOn)
        } catch {
            launchStatus.stringValue = "没改成：\(error.localizedDescription)"
            launchBox.isOn = LaunchAtLogin.isOn
            return
        }
        reload()
    }

    func checkUpdate() {
        updateButton.isEnabled = false
        updateLabel.stringValue = "正在问 GitHub…"
        Task { @MainActor in
            let result = await hooks.updateChecker.check()
            self.showUpdate(result)
        }
    }

    func showUpdate(_ result: UpdateChecker.Result) {
        updateButton.isEnabled = true
        updateLabel.stringValue = UpdateChecker.summary(result)
        if case .newer(_, let notes, let page) = result {
            downloadPage = page
            downloadButton.isHidden = false
            if !notes.isEmpty { updateLabel.stringValue += "\n" + String(notes.prefix(300)) }
        } else {
            downloadButton.isHidden = true
        }
    }

    static func isGranted(_ key: String) -> Bool {
        switch key {
        case "screen": ScreenPermission.isGranted
        case "access": AXIsProcessTrusted()
        case "mic": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        default: false
        }
    }

    static func openPermission(_ key: String) {
        let anchors = ["screen": "Privacy_ScreenCapture", "access": "Privacy_Accessibility", "mic": "Privacy_Microphone",
                       "camera": "Privacy_Camera"]
        if key == "access" { ClipboardPaster.requestAccessibility() }
        if let anchor = anchors[key], let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: 快捷键

@MainActor
final class ShortcutsPane: SettingsPane {
    private(set) var fields: [HotKeyAction: ShortcutField] = [:]
    private(set) var resetButtons: [HotKeyAction: ClosureButton] = [:]
    let message = NSTextField(wrappingLabelWithString: "")

    override func build() {
        for action in HotKeyAction.allCases {
            let field = ShortcutField(action: action)
            field.onStart = { [weak self] f in self?.fields.values.filter { $0 !== f }.forEach { $0.stopRecording() } }
            field.onMessage = { [weak self] text, warning in
                self?.message.stringValue = text
                self?.message.textColor = warning ? Theme.warning : .secondaryLabelColor
            }
            field.onChange = { [weak self] in
                self?.hooks.reloadHotKeys()
                self?.reload()
            }
            fields[action] = field
            let reset = ClosureButton(title: "恢复默认") { [weak self] in
                Settings.resetHotKey(action)
                self?.hooks.reloadHotKeys()
                self?.reload()
                self?.message.stringValue = "\(action.title)恢复成 \(Settings.hotKey(action)?.display ?? "没设")"
                self?.message.textColor = .secondaryLabelColor
            }
            resetButtons[action] = reset
            row(action.title, [field, reset])
        }
        message.font = Theme.small()
        message.preferredMaxLayoutWidth = 440
        message.stringValue = "点一个快捷键，再按你想要的组合；Esc 不改了，⌫ 清掉"
        message.textColor = .secondaryLabelColor
        row("", [message])
        let apply = { [weak self] (scheme: HotKeyScheme) in
            Settings.apply(scheme)
            self?.hooks.reloadHotKeys()
            self?.reload()
            self?.message.stringValue = "✓ 换成了 \(scheme.summary)"
            self?.message.textColor = .secondaryLabelColor
        }
        row("一键套用", [ClosureButton(title: "⌘1–⌘6") { apply(.command) }, ClosureButton(title: "⌃⇧1–⌃⇧6") { apply(.control) }])
        row("", [note("屏幕画笔只在录屏时、或开着画笔时才占这个键。紧急退出 ⌃⌥⌘Q 固定不能改（卡住时救命用）。和别的软件撞了系统不会告诉 MacKit：按了没反应就换一个")])
    }

    override func reload() {
        for (action, field) in fields { field.refresh(); resetButtons[action]?.isEnabled = Settings.isCustomHotKey(action) }
    }

    func stopRecording() { fields.values.forEach { $0.stopRecording() } }
}

/// 一个快捷键：平时显示现在的组合；点一下变成"按下新的快捷键…"，你按什么就是什么
@MainActor
final class ShortcutField: NSButton {
    let hotKeyAction: HotKeyAction
    var onStart: ((ShortcutField) -> Void)?
    var onChange: (() -> Void)?
    var onMessage: ((String, Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init(action: HotKeyAction) {
        hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        self.action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func refresh() {
        title = isRecording ? "按下新的快捷键…" : (Settings.hotKey(hotKeyAction)?.display ?? "未设置")
    }

    @objc private func clicked() { isRecording ? stopRecording() : startRecording() }

    func startRecording(listen: Bool = true) {
        guard !isRecording else { return }
        onStart?(self)
        isRecording = true
        HotKeyCenter.shared.suspend()                         // 先把 MacKit 自己的快捷键全摘掉，免得按 ⌘1 直接截了图
        if listen {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording else { return event }
                let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var mods: KeyModifiers = []
                if m.contains(.command) { mods.insert(.command) }
                if m.contains(.shift) { mods.insert(.shift) }
                if m.contains(.option) { mods.insert(.option) }
                if m.contains(.control) { mods.insert(.control) }
                self.handle(keyCode: event.keyCode, modifiers: mods)
                return nil
            }
        }
        onMessage?("按下新的快捷键（\(hotKeyAction.title)）；Esc 不改了，⌫ 清掉", false)
        refresh()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.resume()
        refresh()
    }

    /// 按了一个组合（自检也直接调这里）
    func handle(keyCode: UInt16, modifiers: KeyModifiers) {
        if modifiers.isEmpty && keyCode == 53 {                       // Esc：不改了
            stopRecording()
            onMessage?("没改", false)
            return
        }
        if modifiers.isEmpty && (keyCode == 51 || keyCode == 117) {   // ⌫：清掉
            Settings.setHotKey(nil, for: hotKeyAction)
            stopRecording()
            onMessage?("\(hotKeyAction.title)不要快捷键了（菜单里照样能点）", false)
            onChange?()
            return
        }
        switch HotKeyRules.check(keyCode: keyCode, modifiers: modifiers, others: Settings.otherHotKeys(than: hotKeyAction)) {
        case .ok:
            let combo = HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
            Settings.setHotKey(combo, for: hotKeyAction)
            stopRecording()
            onMessage?("✓ \(hotKeyAction.title)改成 \(combo.display)", false)
            onChange?()
        case .needsModifier:
            onMessage?("要带上 ⌘、⌃ 或 ⌥（单按字母、数字会挡住你打字）；F1–F12 可以单按", true)
        case .sameAs(let name):
            onMessage?("和\u{201C}\(name)\u{201D}撞了，换一个", true)
        case .reserved(let why):
            onMessage?("\(why)是系统或各个软件常用的，换一个", true)
        }
    }
}

// MARK: 截图

@MainActor
final class ScreenshotPane: SettingsPane {
    private(set) var saveBox: ClosureCheckbox!
    private(set) var quickBox: ClosureCheckbox!
    let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var folderLabel: NSTextField?

    override func build() {
        saveBox = checkbox("截图时同时存成 PNG 文件") { Settings.saveToFile = $0 }
        row("保存", [saveBox])
        folderLabel = folderRow("保存位置", get: { Settings.saveFolder }, set: { Settings.saveFolder = $0 },
                                defaultURL: Settings.defaultSaveFolder)
        quickBox = checkbox("快速模式：松手直接复制，不出标注工具栏") { Settings.screenshotQuickMode = $0 }
        row("框选后", [quickBox])
        colorPopup.addItems(withTitles: ["HEX，比如 #FF3B30", "RGB，比如 255, 59, 48"])
        colorPopup.target = self
        colorPopup.action = #selector(colorPicked)
        row("按 C 取色", [colorPopup])
    }

    override func reload() {
        saveBox?.isOn = Settings.saveToFile
        quickBox?.isOn = Settings.screenshotQuickMode
        colorPopup.selectItem(at: Settings.colorAsHex ? 0 : 1)
        folderLabel?.stringValue = (Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath
    }

    @objc func colorPicked() { Settings.colorAsHex = colorPopup.indexOfSelectedItem == 0 }
}

// MARK: 录屏

@MainActor
final class RecordPane: SettingsPane {
    let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var previewBox: ClosureCheckbox!
    private var folderLabel: NSTextField?

    override func build() {
        qualityPopup.addItems(withTitles: RecordQuality.allCases.map(\.title))
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityPicked)
        row("画质", [qualityPopup])
        previewBox = checkbox("录完自动打开预览（能剪头剪尾、存成 GIF）") { Settings.recordOpenPreview = $0 }
        row("录完", [previewBox])
        folderLabel = folderRow("保存位置", get: { Settings.recordFolder }, set: { Settings.recordFolder = $0 },
                                defaultURL: Settings.defaultRecordFolder)
        row("", [note("系统声音、麦克风、点击、按键、摄像头在每次录屏前的控制条上开关")])
    }

    override func reload() {
        qualityPopup.selectItem(at: RecordQuality.allCases.firstIndex(of: Settings.recordQuality) ?? 0)
        previewBox?.isOn = Settings.recordOpenPreview
        folderLabel?.stringValue = (Settings.recordFolder.path as NSString).abbreviatingWithTildeInPath
    }

    @objc func qualityPicked() {
        let all = RecordQuality.allCases
        let i = qualityPopup.indexOfSelectedItem
        if all.indices.contains(i) { Settings.recordQuality = all[i] }
    }
}

// MARK: 剪贴板

@MainActor
final class ClipboardPane: SettingsPane {
    private(set) var pauseBox: ClosureCheckbox!
    /// 连续粘贴贴完按 Tab（台阶 23）
    private(set) var queueTabBox: ClosureCheckbox!
    let ignoreLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let pasteLabel = NSTextField(labelWithString: "")
    private(set) var clearButton: ClosureButton!
    private var pasteButton: ClosureButton?

    override func build() {
        pauseBox = checkbox("暂停记录（复制的东西先不进历史）") { Settings.clipboardPaused = $0 }
        row("记录", [pauseBox])
        row("不记录的软件", [ignoreLabel, ClosureButton(title: "管理…") { [weak self] in self?.hooks.openIgnoreList() }])
        clearButton = ClosureButton(title: "清空历史（保留收藏的）") { [weak self] in
            self?.hooks.clearClipboard()
            self?.reload()
        }
        countLabel.textColor = .secondaryLabelColor
        row("历史", [countLabel, clearButton])
        queueTabBox = checkbox("贴完自动按 Tab，跳到下一个格子") { Settings.pasteQueueTab = $0 }
        row("连续粘贴", [queueTabBox])
        let go = ClosureButton(title: "去打开") {
            ClipboardPaster.requestAccessibility()
            ClipboardPaster.openAccessibilitySettings()
        }
        pasteButton = go
        row("自动粘贴", [pasteLabel, go])
        row("", [note("回车直接粘贴到原来的软件、连续粘贴，都要\u{201C}辅助功能\u{201D}权限")])
    }

    override func reload() {
        pauseBox?.isOn = Settings.clipboardPaused
        queueTabBox?.isOn = Settings.pasteQueueTab
        ignoreLabel.stringValue = "\(ClipboardIgnoreList.ids.count) 个"
        let c = hooks.clipboardCounts()
        countLabel.stringValue = "\(c.all) 条，其中收藏 \(c.favorites) 条"
        clearButton?.isEnabled = c.all > c.favorites
        pasteLabel.stringValue = ClipboardPaster.canAutoPaste ? "已开启 ✓" : "未开启"
        pasteButton?.isHidden = ClipboardPaster.canAutoPaste
    }
}
