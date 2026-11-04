import AppKit

/// 录制前的小控制条：🔊 系统声音、🎙 麦克风、● 开始录制、✕ 不录了。挂在要录的区域下方
@MainActor
final class RecordingControlBar {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var systemAudio: Bool
    private(set) var microphone: Bool
    let panel: NSPanel
    private var audioButton: ToolbarButton!
    private var micButton: ToolbarButton!
    private(set) var buttons: [ToolbarButton] = []

    init(systemAudio: Bool, microphone: Bool) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.canHide = false                         // 选完区域 MacKit 会藏起来交还焦点，控制条要留着
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        audioButton = ToolbarButton(symbol: "speaker.wave.2", tip: "") { [weak self] in self?.toggleAudio() }
        micButton = ToolbarButton(symbol: "mic.slash", tip: "") { [weak self] in self?.toggleMic() }
        let start = ToolbarButton(symbol: "record.circle.fill", title: "开始录制", tip: "开始录制（⌘4）", width: 104) { [weak self] in
            self?.onStart?()
        }
        start.contentTintColor = .systemRed
        let cancel = ToolbarButton(symbol: "xmark", tip: "不录了") { [weak self] in self?.onCancel?() }
        buttons = [audioButton, micButton, start, cancel]

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.setContentSize(row.fittingSize)
        refresh()
    }

    private func toggleAudio() { systemAudio.toggle(); Settings.recordSystemAudio = systemAudio; refresh() }
    private func toggleMic() { microphone.toggle(); Settings.recordMicrophone = microphone; refresh() }

    private func refresh() {
        audioButton.setSymbol(systemAudio ? "speaker.wave.2" : "speaker.slash",
                              tip: systemAudio ? "系统声音：开（点一下关掉）" : "系统声音：关（点一下打开）")
        micButton.setSymbol(microphone ? "mic" : "mic.slash",
                            tip: microphone ? "麦克风：开（点一下关掉）" : "麦克风：关（点一下打开）")
        audioButton.isSelectedLook = systemAudio
        micButton.isSelectedLook = microphone
    }

    /// 放在要录的区域下方、右对齐；下面放不下就放上面；整屏时放在屏幕底部中间
    func show(near frame: CGRect, on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        let size = panel.frame.size
        let origin = EditGeometry.toolbarOrigin(size: size, selection: frame, bounds: visible)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// 框中间的 3、2、1
@MainActor
final class CountdownWindow {
    let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init(center: CGPoint) {
        let size = CGSize(width: 140, height: 140)
        panel = NSPanel(contentRect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        bg.layer?.cornerRadius = 70
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 24, width: size.width, height: 92)
        bg.addSubview(label)
        panel.contentView = bg
    }

    func show(_ n: Int) {
        label.stringValue = "\(n)"
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// 录制区域四周的红色虚线框。画在区域外面，鼠标能穿过去，录制时从画面里排除
@MainActor
final class RecordingBorderWindow {
    static let gap: CGFloat = 4
    let panel: NSPanel

    init(region: CGRect) {
        let frame = region.insetBy(dx: -Self.gap - 2, dy: -Self.gap - 2)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let line = CAShapeLayer()
        line.path = CGPath(rect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 1.5, dy: 1.5), transform: nil)
        line.fillColor = nil
        line.strokeColor = NSColor.systemRed.cgColor
        line.lineWidth = 2
        line.lineDashPattern = [8, 5]
        view.layer?.addSublayer(line)
        panel.contentView = view
    }

    var windowNumber: CGWindowID { CGWindowID(panel.windowNumber) }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}

/// 录制中的小条：● 00:42 🔊 🎙 ■ 停止。挂在录制区域旁边，红点一闪一闪；能拖走；不会录进视频
@MainActor
final class RecordingHUD {
    var onStop: (() -> Void)?
    let panel: NSPanel
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSView()
    private(set) var stopButton: ToolbarButton!

    init(systemAudio: Bool, microphone: Bool) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true              // 挡视线就拖走
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        var views: [NSView] = [dot, timeLabel]
        for (on, symbol, tip) in [(systemAudio, "speaker.wave.2.fill", "在录系统声音"), (microphone, "mic.fill", "在录麦克风")] where on {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage())
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
            icon.toolTip = tip
            views.append(icon)
        }
        stopButton = ToolbarButton(symbol: "stop.fill", title: "停止", tip: "停止录制（⌘4）", width: 70) { [weak self] in
            self?.onStop?()
        }
        stopButton.contentTintColor = .white
        views.append(stopButton)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        let fit = row.fittingSize
        panel.setContentSize(CGSize(width: fit.width, height: max(fit.height, 36)))
    }

    var timeText: String { timeLabel.stringValue }
    var windowNumber: CGWindowID { CGWindowID(panel.windowNumber) }

    func update(_ text: String) { timeLabel.stringValue = text }

    func show(near target: CGRect, on screen: NSScreen?, fullScreen: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? target
        panel.setFrameOrigin(RecordGeometry.hudOrigin(size: panel.frame.size, target: target, visible: visible,
                                                      fullScreen: fullScreen))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

