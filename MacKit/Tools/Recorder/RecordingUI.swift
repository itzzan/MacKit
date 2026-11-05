import AppKit

/// 录制前的小控制条：🔊 系统声音、🎙 麦克风、🖱 点击、⌨ 按键、📷 摄像头、⏱ 录多久自动停、⏰ 几点开始、● 开始录制、✕ 不录了
@MainActor
final class RecordingControlBar {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 📷 开关变了（RecorderTool 打开 / 关掉摄像头画面）
    var onCameraChange: ((Bool) -> Void)?
    private(set) var systemAudio: Bool
    private(set) var microphone: Bool
    private(set) var showClicks: Bool
    private(set) var showKeys: Bool
    private(set) var camera: Bool
    /// 录的是单个窗口：按键牌子和摄像头录不进去，开了要提示
    let windowTarget: Bool
    private var clicksButton: ToolbarButton!
    private var keysButton: ToolbarButton!
    private var cameraButton: ToolbarButton!
    private let hint = NSTextField(labelWithString: "录窗口时按键和摄像头录不进去，想要的话改成框选区域")
    private var stack: NSStackView!
    private var lastAnchor: (CGRect, NSScreen?)?
    /// 录多久自动停（分钟），0 = 不限时
    private(set) var autoStopMinutes = 0
    /// 几点开始，nil = 立即开始
    private(set) var startAt: Date?
    let panel: NSPanel
    private var audioButton: ToolbarButton!
    private var micButton: ToolbarButton!
    private var stopTimerButton: ToolbarButton!
    private var startTimeButton: ToolbarButton!
    private(set) var buttons: [ToolbarButton] = []
    private var picker: TimePickerPanel?

    init(systemAudio: Bool, microphone: Bool, showClicks: Bool = false, showKeys: Bool = false, camera: Bool = false,
         windowTarget: Bool = false) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.showClicks = showClicks
        self.showKeys = showKeys
        self.camera = camera
        self.windowTarget = windowTarget
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
        clicksButton = ToolbarButton(symbol: "cursorarrow.click.2", tip: "") { [weak self] in self?.toggleClicks() }
        keysButton = ToolbarButton(symbol: "keyboard", tip: "") { [weak self] in self?.toggleKeys() }
        cameraButton = ToolbarButton(symbol: "video.slash", tip: "") { [weak self] in self?.toggleCamera() }
        stopTimerButton = ToolbarButton(symbol: "timer", title: "不限时", tip: "录多久自动停", width: 104) { [weak self] in
            self?.showStopTimerMenu()
        }
        startTimeButton = ToolbarButton(symbol: "alarm", title: "立即开始", tip: "几点开始录", width: 120) { [weak self] in
            self?.showStartTimeMenu()
        }
        let start = ToolbarButton(symbol: "circle.fill", title: "开始录制", tip: "开始录制（⌘4）", style: .primary) { [weak self] in
            self?.onStart?()
        }
        let cancel = ToolbarButton(symbol: "xmark", tip: "不录了") { [weak self] in self?.onCancel?() }
        buttons = [audioButton, micButton, clicksButton, keysButton, cameraButton, stopTimerButton, startTimeButton, start, cancel]

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 4
        hint.font = Theme.small()
        hint.textColor = Theme.warning
        stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.edgeInsets = Theme.barInsets
        panel.contentView = Theme.bar(containing: stack)
        refresh()
    }

    /// 录窗口时开了按键或摄像头：提示录不进去
    var showsWindowHint: Bool { !hint.isHidden }

    /// 台阶 10 起统一用 Theme.bar；留着这个名字给老代码
    static func hudBackground(containing row: NSView, cornerRadius: CGFloat = Theme.barRadius) -> NSView {
        Theme.bar(containing: row, radius: cornerRadius)
    }

    private func toggleAudio() { systemAudio.toggle(); Settings.recordSystemAudio = systemAudio; refresh() }
    private func toggleMic() { microphone.toggle(); Settings.recordMicrophone = microphone; refresh() }
    private func toggleClicks() { showClicks.toggle(); Settings.recordShowClicks = showClicks; refresh() }
    private func toggleKeys() { showKeys.toggle(); Settings.recordShowKeys = showKeys; refresh() }
    private func toggleCamera() { setCamera(!camera, remember: true); onCameraChange?(camera) }

    /// 摄像头没权限时 RecorderTool 会把开关拨回来
    func setCamera(_ on: Bool, remember: Bool = false) {
        camera = on
        if remember { Settings.recordCamera = on }
        refresh()
    }

    func setAutoStop(minutes: Int) { autoStopMinutes = minutes; refresh() }
    func setStart(at date: Date?) { startAt = date; refresh() }

    private func refresh() {
        audioButton.setSymbol(systemAudio ? "speaker.wave.2" : "speaker.slash",
                              tip: systemAudio ? "系统声音：开（点一下关掉）" : "系统声音：关（点一下打开）")
        micButton.setSymbol(microphone ? "mic" : "mic.slash",
                            tip: microphone ? "麦克风：开（点一下关掉）" : "麦克风：关（点一下打开）")
        audioButton.isSelectedLook = systemAudio
        micButton.isSelectedLook = microphone
        stopTimerButton.setTitle(RecordSchedule.autoStopTitle(autoStopMinutes))
        stopTimerButton.isSelectedLook = autoStopMinutes > 0
        startTimeButton.setTitle(RecordSchedule.startTitle(startAt, now: Date()))
        startTimeButton.isSelectedLook = startAt != nil
        clicksButton.isSelectedLook = showClicks
        clicksButton.toolTip = showClicks ? "显示鼠标点击：开" : "显示鼠标点击：关"
        keysButton.isSelectedLook = showKeys
        keysButton.toolTip = showKeys ? "显示按了什么键：开（只显示快捷键和功能键）" : "显示按了什么键：关"
        cameraButton.setSymbol(camera ? "video.fill" : "video.slash", tip: camera ? "摄像头：开" : "摄像头：关")
        cameraButton.isSelectedLook = camera
        hint.isHidden = !(windowTarget && (showKeys || camera))
        stack?.layoutSubtreeIfNeeded()
        if let stack { panel.setContentSize(stack.fittingSize) }
        if let (frame, screen) = lastAnchor { move(near: frame, on: screen) }
    }

    private func showStopTimerMenu() {
        let menu = NSMenu()
        for minutes in RecordSchedule.autoStopChoices {
            let item = ActionMenuItem(minutes == 0 ? "不限时（自己停）" : "录 \(minutes) 分钟后自动停") { [weak self] in
                self?.setAutoStop(minutes: minutes)
            }
            item.state = minutes == autoStopMinutes ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: stopTimerButton.bounds.height + 4), in: stopTimerButton)
    }

    private func showStartTimeMenu() {
        let menu = NSMenu()
        let now = ActionMenuItem("立即开始") { [weak self] in self?.setStart(at: nil) }
        now.state = startAt == nil ? .on : .off
        menu.addItem(now)
        for minutes in RecordSchedule.startInChoices {
            menu.addItem(ActionMenuItem("\(minutes) 分钟后开始") { [weak self] in
                self?.setStart(at: Date().addingTimeInterval(Double(minutes * 60)))
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("指定时间…") { [weak self] in self?.pickTime() })
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: startTimeButton.bounds.height + 4), in: startTimeButton)
    }

    private func pickTime() {
        let p = TimePickerPanel(initial: startAt ?? Date().addingTimeInterval(5 * 60))
        p.onDone = { [weak self] date in
            if let date { self?.setStart(at: date) }
            self?.picker = nil
        }
        picker = p
        p.show()
    }

    /// 放在要录的区域下方、右对齐；下面放不下就放上面
    func show(near frame: CGRect, on screen: NSScreen?) {
        move(near: frame, on: screen)
        panel.orderFrontRegardless()
    }

    /// 录制框改了大小 / 挪了位置：控制条跟着走
    func move(near frame: CGRect, on screen: NSScreen?) {
        lastAnchor = (frame, screen)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        let size = panel.frame.size
        panel.setFrameOrigin(EditGeometry.toolbarOrigin(size: size, selection: frame.insetBy(dx: -RecordingBorderWindow.margin,
                                                                                          dy: -RecordingBorderWindow.margin),
                                                        bounds: visible))
    }

    func close() {
        picker?.close()
        panel.orderOut(nil)
    }
}

/// "几点开始录"的小窗口
@MainActor
final class TimePickerPanel: NSObject, NSWindowDelegate {
    var onDone: ((Date?) -> Void)?
    let window: NSPanel
    let picker = NSDatePicker()

    init(initial: Date) {
        window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 110), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        super.init()
        window.title = "几点开始录"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = initial
        let ok = NSButton(title: "确定", target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(dismiss))
        let hint = NSTextField(labelWithString: "今天这个时间已经过了，就算明天")
        hint.font = Theme.small()
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [cancel, ok])
        let stack = NSStackView(views: [picker, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        window.contentView = stack
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func confirm() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        let date = RecordSchedule.nextStart(hour: c.hour ?? 0, minute: c.minute ?? 0, now: Date())
        finish(date)
    }

    @objc private func dismiss() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ date: Date?) {
        guard let callback = onDone else { return }
        onDone = nil
        window.orderOut(nil)
        callback(date)
        if NSApp.isActive, NSApp.modalWindow == nil { NSApp.hide(nil) }       // 焦点还给原来的软件
    }

    func close() { finish(nil) }
}

/// 框中间的 3、2、1
@MainActor
final class CountdownWindow {
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")

    /// hint：数字下面一行小字（延时截图写"Esc 取消"）
    init(center: CGPoint, hint: String? = nil) {
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
        let bg = Theme.surface(radius: size.width / 2)
        bg.frame = CGRect(origin: .zero, size: size)
        label.font = Theme.number(72, .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 24, width: size.width, height: 92)
        bg.addSubview(label)
        if let hint {
            let small = NSTextField(labelWithString: hint)
            small.font = Theme.small(.medium)
            small.textColor = Theme.secondaryText
            small.alignment = .center
            small.frame = CGRect(x: 0, y: 18, width: size.width, height: 16)
            bg.addSubview(small)
        }
        panel.contentView = bg
    }

    func show(_ n: Int) {
        label.stringValue = "\(n)"
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

/// 录制区域四周的红色虚线框。画在区域外面，录制时从画面里排除。
/// 开录之前能调（2026-11-04 验收：录制框不能调大小）：拖 8 个小方块改大小、拖虚线挪位置。
/// 只有鼠标靠近虚线时窗口才接鼠标，框里面照常能点下面的软件。开始倒数后锁定
@MainActor
final class RecordingBorderWindow {
    static let margin: CGFloat = 12              // 窗口比录制区域大一圈，放得下小方块
    let panel: NSPanel
    private(set) var region: CGRect              // 录制区域（全局坐标，点）
    let screenFrame: CGRect
    private(set) var adjustable: Bool
    var onChange: ((CGRect) -> Void)?
    private let view: RecordingBorderView
    private var hoverTimer: Timer?
    private enum Drag { case resize(SelectionHandle, CGRect), move(CGPoint, CGRect) }
    private var drag: Drag?

    /// color：录屏是红色；长截图不是录制，用主题色
    init(region: CGRect, screenFrame: CGRect, adjustable: Bool = true, color: NSColor = Theme.record) {
        self.region = region
        self.screenFrame = screenFrame
        self.adjustable = adjustable
        let frame = region.insetBy(dx: -Self.margin, dy: -Self.margin)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view = RecordingBorderView(frame: CGRect(origin: .zero, size: frame.size))
        view.color = color
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.owner = self
        refreshView()
    }

    var windowNumber: CGWindowID { CGWindowID(panel.windowNumber) }

    func show() {
        panel.orderFrontRegardless()
        if adjustable { startHoverWatch() }
    }

    func close() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        panel.orderOut(nil)
    }

    /// 开始倒数后锁定：不再接鼠标，小方块和提示收起
    func setAdjustable(_ on: Bool) {
        adjustable = on
        drag = nil
        if on { startHoverWatch() } else { hoverTimer?.invalidate(); hoverTimer = nil; panel.ignoresMouseEvents = true }
        refreshView()
    }

    func setRegion(_ r: CGRect) {
        region = RecordGeometry.clampRegion(r, within: screenFrame)
        panel.setFrame(region.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        refreshView()
        onChange?(region)
    }

    private func refreshView() {
        view.adjustable = adjustable
        view.scale = NSScreen.screens.first { $0.frame.intersects(region) }?.backingScaleFactor ?? 2
        view.regionSize = region.size
        view.needsDisplay = true
    }

    /// 鼠标靠近虚线 / 小方块时才接鼠标，别处让给下面的软件（每秒看 30 次鼠标在哪）
    private func startHoverWatch() {
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.adjustable, self.drag == nil else { return }
                let m = NSEvent.mouseLocation
                let onHandle = EditGeometry.handle(at: m, in: self.region, tolerance: 7) != nil
                let grab = onHandle || RecordGeometry.isNearEdge(m, of: self.region)
                if self.panel.ignoresMouseEvents == grab { self.panel.ignoresMouseEvents = !grab }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    // MARK: 拖（鼠标事件和自检都走这里；坐标都是全局的）

    /// 从 p 开始拖：在小方块上 = 改大小；在虚线上 = 挪位置；别处不拖，返回 false
    @discardableResult
    func beginDrag(at p: CGPoint) -> Bool {
        guard adjustable else { return false }
        if let h = EditGeometry.handle(at: p, in: region, tolerance: 7) {
            drag = .resize(h, region)
        } else if RecordGeometry.isNearEdge(p, of: region) {
            drag = .move(p, region)
        } else {
            drag = nil
        }
        return drag != nil
    }

    func drag(to p: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .resize(let h, let original):
            setRegion(EditGeometry.resize(original, handle: h, to: p, bounds: screenFrame))
        case .move(let start, let original):
            setRegion(EditGeometry.move(original, by: CGVector(dx: p.x - start.x, dy: p.y - start.y), within: screenFrame))
        }
    }

    func endDrag() { drag = nil }

    func cursor(at p: CGPoint) -> NSCursor {
        guard adjustable else { return .arrow }
        if let h = EditGeometry.handle(at: p, in: region, tolerance: 7) {
            return NSCursor.frameResize(position: Self.position(h), directions: .all)
        }
        return RecordGeometry.isNearEdge(p, of: region) ? .openHand : .arrow
    }

    private static func position(_ h: SelectionHandle) -> NSCursor.FrameResizePosition {
        switch h {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}

/// 红框窗口里画的东西：虚线、8 个小方块、左上角的尺寸和提示
@MainActor
final class RecordingBorderView: NSView {
    weak var owner: RecordingBorderWindow?
    var adjustable = true
    var scale: CGFloat = 2
    var regionSize: CGSize = .zero
    var color: NSColor = Theme.record
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = RecordingBorderWindow.margin
        let r = bounds.insetBy(dx: m, dy: m)
        // 虚线画在区域外面一点，不会被录进去
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 5])
        ctx.stroke(r.insetBy(dx: -3, dy: -3))
        guard adjustable else { return }
        ctx.setLineDash(phase: 0, lengths: [])
        for h in SelectionHandle.allCases {
            let c = EditGeometry.handleCenter(h, of: r.insetBy(dx: -3, dy: -3))
            let dot = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(dot)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(dot)
        }
        let text = "\(Int(regionSize.width * scale)) × \(Int(regionSize.height * scale))　拖小方块改大小，拖虚线挪位置"
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.small(.medium), .foregroundColor: Theme.text]
        let size = (text as NSString).size(withAttributes: attrs)
        guard size.width + 16 < r.width, size.height + 12 < r.height else { return }
        let box = CGRect(x: r.minX + 6, y: r.maxY - size.height - 10, width: size.width + 10, height: size.height + 4)
        ctx.setFillColor(Theme.solidFill.cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: Theme.labelRadius, cornerHeight: Theme.labelRadius, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { owner?.cursor(at: NSEvent.mouseLocation).set() }
    override func mouseMoved(with event: NSEvent) { owner?.cursor(at: NSEvent.mouseLocation).set() }

    override func mouseDown(with event: NSEvent) {
        if owner?.beginDrag(at: NSEvent.mouseLocation) == true { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) { owner?.drag(to: NSEvent.mouseLocation) }

    override func mouseUp(with event: NSEvent) {
        owner?.endDrag()
        owner?.cursor(at: NSEvent.mouseLocation).set()
    }
}

/// 录制小条：挂在录制区域旁边；能拖走；不会录进视频。四种样子：
/// - 等定时开始：⏰ 20:00 开始 · 还有 01:23　▶ 现在开始　✕ 取消
/// - 录制中：● 00:42 🔊 🎙　⏸ 暂停　■ 停止（红点一闪一闪）
/// - 暂停中：⏸ 已暂停 00:42　▶ 继续　■ 停止
/// - 保存中：保存中…
@MainActor
final class RecordingHUD {
    enum Mode: Equatable { case waiting, recording, paused, saving }

    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStartNow: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 画笔（台阶 16）
    var onPen: (() -> Void)?
    let panel: NSPanel
    private(set) var mode: Mode = .recording
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let stateLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let systemAudio: Bool
    private let microphone: Bool
    private(set) var buttons: [String: ToolbarButton] = [:]

    init(systemAudio: Bool, microphone: Bool) {
        self.systemAudio = systemAudio
        self.microphone = microphone
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
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        timeLabel.font = Theme.number(15)
        timeLabel.textColor = Theme.text
        stateLabel.font = Theme.small(.medium)
        stateLabel.textColor = Theme.secondaryText

        let make = { (key: String, symbol: String, title: String, tip: String, style: ToolbarButton.Style,
                      run: @escaping @MainActor () -> Void) in
            self.buttons[key] = ToolbarButton(symbol: symbol, title: title, tip: tip, style: style, handler: run)
        }
        make("pause", "pause.fill", "暂停", "暂停（暂停期间不录）", .plain) { [weak self] in self?.onPause?() }
        make("resume", "play.fill", "继续", "继续录", .primary) { [weak self] in self?.onResume?() }
        make("stop", "stop.fill", "停止", "停止录制（⌘4）", .danger) { [weak self] in self?.onStop?() }
        make("startNow", "play.fill", "现在开始", "不等了，现在开始（⌘4）", .primary) { [weak self] in self?.onStartNow?() }
        make("cancel", "xmark", "取消", "取消这次录屏", .plain) { [weak self] in self?.onCancel?() }
        make("pen", "pencil.tip", "画笔", "在屏幕上画，录进视频（⌃⇧D）", .plain) { [weak self] in self?.onPen?() }
        setMode(.recording)
    }

    var timeText: String { timeLabel.stringValue }
    var windowNumber: CGWindowID { CGWindowID(panel.windowNumber) }
    /// 红点有没有在闪（自检用）
    var isPulsing: Bool { dot.layer?.animation(forKey: "pulse") != nil }

    func update(_ text: String) { timeLabel.stringValue = text }

    /// 画笔开着：按钮亮成主题色
    func setPenOn(_ on: Bool) { buttons["pen"]?.isSelectedLook = on }

    /// 换样子：右边缘不动，宽度跟着变
    func setMode(_ newMode: Mode) {
        mode = newMode
        dot.layer?.removeAllAnimations()
        var views: [NSView] = []
        switch newMode {
        case .waiting:
            let icon = NSImageView(image: NSImage(systemSymbolName: "alarm", accessibilityDescription: "等着开始") ?? NSImage())
            icon.contentTintColor = Theme.text
            views = [icon, timeLabel, buttons["startNow"]!, buttons["cancel"]!]
        case .recording:
            dot.layer?.backgroundColor = Theme.record.cgColor
            // 红点慢慢"呼吸"，一眼看出正在录（这个小条本身不会被录进去）
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
            views = [dot, timeLabel]
            for (on, symbol, tip) in [(systemAudio, "speaker.wave.2.fill", "在录系统声音"), (microphone, "mic.fill", "在录麦克风")] where on {
                let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage())
                icon.contentTintColor = Theme.secondaryText
                icon.toolTip = tip
                views.append(icon)
            }
            views += [Theme.dividerView(), buttons["pen"]!, buttons["pause"]!, buttons["stop"]!]
        case .paused:
            dot.layer?.backgroundColor = NSColor.systemGray.cgColor
            stateLabel.stringValue = "已暂停"
            views = [dot, stateLabel, timeLabel, Theme.dividerView(), buttons["pen"]!, buttons["resume"]!, buttons["stop"]!]
        case .saving:
            dot.layer?.backgroundColor = NSColor.systemGray.cgColor
            stateLabel.stringValue = "保存中"
            views = [dot, stateLabel, timeLabel]
        }
        let row = Theme.row(views, spacing: 8, insets: NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 6))
        let background = Theme.bar(containing: row)
        if newMode == .recording { background.layer?.borderColor = Theme.record.withAlphaComponent(0.55).cgColor }
        let rightEdge = panel.frame.maxX
        let wasShown = panel.frame.width > 0
        panel.contentView = background
        let fit = row.fittingSize
        panel.setContentSize(CGSize(width: fit.width, height: max(fit.height, 38)))
        if wasShown { panel.setFrameOrigin(CGPoint(x: rightEdge - panel.frame.width, y: panel.frame.minY)) }
    }

    func show(near target: CGRect, on screen: NSScreen?, fullScreen: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? target
        panel.setFrameOrigin(RecordGeometry.hudOrigin(size: panel.frame.size, target: target, visible: visible,
                                                      fullScreen: fullScreen))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

