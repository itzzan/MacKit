import AppKit
import ApplicationServices

/// 项目主页、发布页（1.0 起，"关于 MacKit"里用）
enum AppLinks {
    static let home = URL(string: "https://github.com/itzzan/MacKit")!
    static let releases = URL(string: "https://github.com/itzzan/MacKit/releases")!
}

/// 欢迎窗口（1.0 起）：新用户第一次打开时出现；以后在"关于 MacKit → 使用说明"里再打开。
/// 讲 MacKit 住在哪、要开哪些权限（每个后面一个"去打开"）、用哪套快捷键
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    /// 换了一套快捷键（AppDelegate 让各积木重新注册）
    var onSchemeChange: ((HotKeyScheme) -> Void)?
    var onClose: (() -> Void)?
    private(set) var schemeButtons: [HotKeyScheme: NSButton] = [:]
    private(set) var permissionRows: [String: (status: NSImageView, button: NSButton?)] = [:]
    private let summary = NSTextField(labelWithString: "")
    /// 开机自动启动（台阶 17）：默认不勾
    let launchBox = ClosureCheckbox(title: "开机自动启动 MacKit（以后在「设置… → 通用」里也能改）")
    /// 自检时 true：勾了也不真的去加登录项
    var dryRun = false
    private var timer: Timer?

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "欢迎使用 MacKit"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = build()
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
        refresh()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 开着时每 1.5 秒看一眼权限开了没有（只是读状态）
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }

    // MARK: 界面

    private func build() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "欢迎使用 MacKit \(AppInfo.version)")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = wrapping("截图、贴图、录屏、剪贴板历史、识别文字……都在屏幕右上角菜单栏的扳手图标里。所有东西都留在你的电脑上，MacKit 平时不联网（只有你点\u{201C}检查更新\u{201D}时问一下 GitHub）。")
        let head = NSStackView(views: [icon, vstack([title, subtitle], spacing: 4)])
        head.alignment = .centerY
        head.spacing = 14

        let screen = permissionRow(key: "screen", title: "屏幕录制", detail: "截图、录屏都要用，必须开") {
            ScreenPermission.requestAndOpenSettings()
        }
        let access = permissionRow(key: "accessibility", title: "辅助功能",
                                   detail: "剪贴板历史回车自动粘贴、长截图自动滚动时要用，可以先不开") {
            ClipboardPaster.requestAccessibility()
            ClipboardPaster.openAccessibilitySettings()
        }
        let media = permissionRow(key: "media", title: "麦克风、摄像头", detail: "录屏时打开了才会问你，现在不用管", action: nil)

        var radios: [NSView] = []
        for scheme in HotKeyScheme.allCases {
            let b = NSButton(radioButtonWithTitle: scheme.title, target: self, action: #selector(pickScheme(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(scheme.rawValue)
            schemeButtons[scheme] = b
            radios.append(b)
        }
        summary.font = Theme.number(Theme.bodySize, .regular)
        summary.textColor = .secondaryLabelColor
        let later = small("以后在菜单最下面的「设置…」里还能一个一个随便改；QQ、Snipaste 这类软件开着时，可能会和它们抢同一个快捷键")
        launchBox.handler = { [weak self] _ in self?.launchToggled() }
        launchBox.isOn = LaunchAtLogin.isOn                  // 默认不勾（拍板）；以前在设置里勾过的照实显示

        let foot = small("卡住时按 ⌃⌥⌘Q 紧急退出　·　这个窗口以后在菜单「关于 MacKit → 使用说明」里还能打开")
        let start = NSButton(title: "开始使用", target: self, action: #selector(finish))
        start.keyEquivalent = "\r"
        start.bezelStyle = .rounded
        let footRow = NSStackView(views: [foot, start])
        footRow.alignment = .centerY
        footRow.spacing = 12
        foot.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = vstack([head, section("1　打开权限"), screen, access, media,
                            section("2　选一套快捷键"), vstack(radios, spacing: 6), summary, later,
                            section("3　要不要开机自动启动"), launchBox, footRow], spacing: 12)
        stack.setCustomSpacing(20, after: head)
        stack.setCustomSpacing(20, after: media)
        stack.setCustomSpacing(20, after: later)
        stack.setCustomSpacing(20, after: launchBox)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 22, right: 28)
        stack.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return stack
    }

    private func launchToggled() {
        guard !dryRun else { return }
        do { try LaunchAtLogin.set(launchBox.isOn) } catch { launchBox.isOn = LaunchAtLogin.isOn }
    }

    private func permissionRow(key: String, title: String, detail: String, action: (@MainActor () -> Void)?) -> NSView {
        let status = NSImageView()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: Theme.bodySize, weight: .semibold)
        let texts = vstack([name, small(detail)], spacing: 2)
        status.setContentHuggingPriority(.required, for: .horizontal)
        texts.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()                                  // 把"去打开"推到最右边
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [status, texts, spacer]
        var button: NSButton?
        if let action {
            let b = ClosureButton(title: "去打开", handler: action)
            b.bezelStyle = .rounded
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 84).isActive = true
            views.append(b)
            button = b
        }
        permissionRows[key] = (status, button)
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 544).isActive = true
        return row
    }

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .bold)
        return label
    }

    private func small(_ text: String) -> NSTextField {
        let label = wrapping(text)
        label.font = Theme.small()
        label.textColor = .secondaryLabelColor
        return label
    }

    private func wrapping(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    // MARK: 状态

    /// 权限开了没有、现在是哪套快捷键
    func refresh() {
        setStatus("screen", on: ScreenPermission.isGranted)
        setStatus("accessibility", on: AXIsProcessTrusted())
        setStatus("media", on: nil)
        let current = Settings.hotKeyScheme
        for (scheme, b) in schemeButtons { b.state = scheme == current ? .on : .off }
        summary.stringValue = current?.summary ?? "现在用的是你自己单独设的快捷键"
    }

    private func setStatus(_ key: String, on: Bool?) {
        guard let row = permissionRows[key] else { return }
        let (symbol, color): (String, NSColor) = switch on {
        case true?: ("checkmark.circle.fill", Theme.success)
        case false?: ("circle", .tertiaryLabelColor)
        case nil: ("minus.circle", .tertiaryLabelColor)
        }
        row.status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        row.status.contentTintColor = color
        row.button?.title = on == true ? "已开启" : "去打开"
        row.button?.isEnabled = on != true
    }

    var isScreenGrantedShown: Bool { permissionRows["screen"]?.button?.title == "已开启" }

    @objc private func pickScheme(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let scheme = HotKeyScheme(rawValue: raw) else { return }
        choose(scheme)
    }

    /// 选一套快捷键（自检也调这里）
    func choose(_ scheme: HotKeyScheme) {
        Settings.apply(scheme)
        Log.app.notice("welcome: hotkey scheme \(scheme.rawValue, privacy: .public)")
        onSchemeChange?(scheme)
        refresh()
    }

    @objc private func finish() { window.close() }
}

/// 带闭包的普通按钮
@MainActor
final class ClosureButton: NSButton {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}
