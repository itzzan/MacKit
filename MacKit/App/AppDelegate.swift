import AppKit

/// 程序入口：菜单栏图标 + 各块积木
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(selfTest: CommandLine.arguments.contains("--selftest"))
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)      // 只在菜单栏，不进 Dock
        app.run()
    }

    private let selfTest: Bool
    private var statusItem: NSStatusItem?
    private let screenshot = ScreenshotTool()
    private let pin = PinTool()
    private let clipboard = ClipboardTool()
    private let recorder = RecorderTool()
    private let ocr = OCRTool()
    private let measure = MeasureTool()
    private let longShot = LongShotTool()
    private let status = SystemStatusTool()
    private let keepAwake = KeepAwakeTool()
    private let windowTips = WindowTipsTool()
    private let beautify = BeautifyTool()
    private let screenPen = ScreenPenTool()
    private lazy var modules: [ToolModule] = [status, screenshot, longShot, pin, clipboard, recorder, ocr, measure,
                                              keepAwake, windowTips, beautify, screenPen]
    /// 菜单分组（台阶 10）：每组一个小标题，常用操作放第一层，设置收进这一组最后的"设置"子菜单
    private struct MenuGroup {
        let title: String
        let modules: [ToolModule]
        let settingsTitle: String?
    }
    private lazy var menuGroups: [MenuGroup] = [
        MenuGroup(title: "系统状态（点一下打开活动监视器）", modules: [status], settingsTitle: nil),
        MenuGroup(title: "截图", modules: [screenshot, longShot, pin], settingsTitle: "截图设置"),
        MenuGroup(title: "录屏", modules: [recorder], settingsTitle: "录屏设置"),
        MenuGroup(title: "剪贴板", modules: [clipboard], settingsTitle: "剪贴板设置"),
        MenuGroup(title: "识别", modules: [ocr, measure], settingsTitle: "识别设置"),
        MenuGroup(title: "小工具", modules: [keepAwake, screenPen, windowTips], settingsTitle: nil),
    ]
    /// 菜单栏图标：录屏中显示红点和时长（优先），防休眠时是咖啡杯，平常是扳手
    private var recordingText: String?
    private var keepAwakeOn = false
    private var welcome: WelcomeWindow?
    private(set) var emergencyQuitRegistered = false

    init(selfTest: Bool) {
        self.selfTest = selfTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 录屏冒烟测试：不建菜单栏、不注册快捷键，录完就退出
        if let i = CommandLine.arguments.firstIndex(of: "--record-smoke"), CommandLine.arguments.indices.contains(i + 1) {
            RecordSmokeTest.run(resultPath: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--make-iconset") {
            IconMaker.run(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--welcome-preview") {
            StylePreview.runWelcome(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--style-preview") {
            StylePreview.run(arguments: CommandLine.arguments)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--pen-smoke"), CommandLine.arguments.indices.contains(i + 1) {
            PenSmokeTest.run(resultPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--longshot-smoke"), CommandLine.arguments.indices.contains(i + 1) {
            LongShotSmokeTest.run(resultPath: CommandLine.arguments[i + 1])
            return
        }
        // 1.0 起：第一次打开。要在注册快捷键之前定好用哪一套
        let firstLaunch = selfTest ? FirstLaunch.nothing
            : FirstLaunch.decide(done: Settings.welcomeDone, hasPreviousData: Settings.hasPreviousData)
        switch firstLaunch {
        case .keepOldHotKeys:
            Settings.pinCurrentHotKeys()                  // 老用户：快捷键原样写下来
            Settings.welcomeDone = true
            Log.app.notice("first launch of 1.0: existing user, hotkeys kept")
        case .welcome:
            Settings.apply(.control)                      // 新用户：先用很少冲突的 ⌃⇧ 那一套
            Log.app.notice("first launch: new user, welcome")
        case .nothing:
            break
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "MacKit")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacKit 工具箱"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        screenshot.onPin = { [weak self] result in self?.pin.pin(result) }
        clipboard.onPin = { [weak self] pb in self?.pin.pinFromPasteboard(pb) }
        recorder.onIndicator = { [weak self] text in self?.showRecordingIndicator(text) }
        screenshot.onRecognize = { [weak self] image in self?.ocr.recognize(image) }
        pin.onRecognize = { [weak self] image in self?.ocr.recognize(image) }
        screenshot.onLongShot = { [weak self] region in self?.longShot.start(region) }
        longShot.onPin = { [weak self] image, size in self?.pin.pinImage(image, pointSize: size) }
        screenshot.onBeautify = { [weak self] result in self?.beautify.open(result.image, pointSize: result.pointSize) }
        pin.onBeautify = { [weak self] image, size in self?.beautify.open(image, pointSize: size) }
        beautify.onPin = { [weak self] image, size in self?.pin.pinImage(image, pointSize: size) }
        screenPen.isRecordingBusy = { [weak self] in self?.recorder.isBusy ?? false }
        keepAwake.dryRun = selfTest                 // 自检时录屏状态变来变去，别真的去挡系统休眠
        recorder.onBusyChange = { [weak self] busy in self?.keepAwake.setRecording(busy) }
        keepAwake.onChange = { [weak self] on in
            self?.keepAwakeOn = on
            self?.refreshStatusIcon()
        }
        for module in modules { module.activate() }
        emergencyQuitRegistered = HotKeyCenter.shared.register(EmergencyHotKey.quit) {
            Log.app.notice("emergency quit")
            exit(0)                          // 不走正常退出流程，卡在对话框里也能退
        } != nil
        Log.app.notice("MacKit \(AppInfo.version, privacy: .public) launched")
        if firstLaunch == .welcome {
            Settings.welcomeDone = true
            showWelcome()
        }

        if selfTest {
            SelfTest.run(statusItem: item, screenshot: screenshot, pin: pin, recorder: recorder, emergencyQuit: emergencyQuitRegistered)
        }
    }

    /// 录屏中：菜单栏图标换成红点，旁边显示时长；nil = 换回扳手
    private func showRecordingIndicator(_ text: String?) {
        recordingText = text
        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if let text = recordingText {
            statusItem?.length = NSStatusItem.variableLength
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "正在录屏")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.imagePosition = .imageLeading
            button.title = " " + text
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            let image = NSImage(systemSymbolName: keepAwakeOn ? "cup.and.saucer.fill" : "wrench.and.screwdriver",
                                accessibilityDescription: keepAwakeOn ? "MacKit（防休眠中）" : "MacKit")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.toolTip = keepAwakeOn ? "MacKit 工具箱（防休眠中）" : "MacKit 工具箱"
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    /// 欢迎窗口（第一次打开、菜单"使用说明"）
    func showWelcome() {
        if let welcome { welcome.show(); return }
        let w = WelcomeWindow()
        w.onSchemeChange = { [weak self] _ in self?.modules.forEach { $0.reloadHotKeys() } }
        w.onClose = { [weak self] in self?.welcome = nil }
        welcome = w
        w.show()
    }

    func menuWillOpen(_ menu: NSMenu) { status.menuOpened() }
    func menuDidClose(_ menu: NSMenu) { status.menuClosed() }

    /// 每次点开菜单都重新生成，这样设置改了马上能看到
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for group in menuGroups {
            let actions = group.modules.flatMap { $0.menuItems() }
            let settings = group.modules.map { $0.settingsItems() }.filter { !$0.isEmpty }
            guard !actions.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: group.title))
            for item in actions { menu.addItem(item) }
            if let title = group.settingsTitle, !settings.isEmpty {
                let sub = NSMenu()
                for (i, part) in settings.enumerated() {
                    if i > 0 { sub.addItem(.separator()) }
                    for item in part { sub.addItem(item) }
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = sub
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if !ScreenPermission.isGranted { menu.addItem(ScreenPermission.menuItem()) }     // 没开权限时第一层就提醒
        let about = NSMenu()
        about.addItem(.info("MacKit \(AppInfo.version)"))
        about.addItem(ActionMenuItem("使用说明（权限、快捷键）…") { [weak self] in self?.showWelcome() })
        about.addItem(ActionMenuItem("打开项目主页") { NSWorkspace.shared.open(AppLinks.home) })
        about.addItem(ActionMenuItem("看看有没有新版本") { NSWorkspace.shared.open(AppLinks.releases) })
        about.addItem(.separator())
        about.addItem(ScreenPermission.menuItem())
        if emergencyQuitRegistered { about.addItem(.info("卡住时按 \(EmergencyHotKey.quit.display) 紧急退出")) }
        let aboutItem = NSMenuItem(title: "关于 MacKit", action: nil, keyEquivalent: "")
        aboutItem.submenu = about
        menu.addItem(aboutItem)
        menu.addItem(ActionMenuItem("退出 MacKit", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }
}
