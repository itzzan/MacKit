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
    private lazy var modules: [ToolModule] = [screenshot, pin, clipboard, recorder, ocr, measure]
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
        for module in modules { module.activate() }
        emergencyQuitRegistered = HotKeyCenter.shared.register(EmergencyHotKey.quit) {
            Log.app.notice("emergency quit")
            exit(0)                          // 不走正常退出流程，卡在对话框里也能退
        } != nil
        Log.app.notice("MacKit \(AppInfo.version, privacy: .public) launched")

        if selfTest {
            SelfTest.run(statusItem: item, screenshot: screenshot, pin: pin, recorder: recorder, emergencyQuit: emergencyQuitRegistered)
        }
    }

    /// 录屏中：菜单栏图标换成红点，旁边显示时长；nil = 换回扳手
    private func showRecordingIndicator(_ text: String?) {
        guard let button = statusItem?.button else { return }
        if let text {
            statusItem?.length = NSStatusItem.variableLength
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "正在录屏")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.imagePosition = .imageLeading
            button.title = " " + text
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "MacKit")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    /// 每次点开菜单都重新生成，这样设置改了马上能看到
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for module in modules {
            for item in module.menuItems() { menu.addItem(item) }
            menu.addItem(.separator())
        }
        menu.addItem(ScreenPermission.menuItem())
        menu.addItem(.separator())
        menu.addItem(.info("MacKit \(AppInfo.version)"))
        menu.addItem(ActionMenuItem("退出 MacKit", key: "q", modifiers: .command) { NSApp.terminate(nil) })
        if emergencyQuitRegistered { menu.addItem(.info("卡住时按 \(EmergencyHotKey.quit.display) 紧急退出")) }
    }
}
