import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 连续粘贴（台阶 14）：先排好几条，在别的软件里每按一次 ⌘V 贴下一条。
///
/// 开着时在系统里挂一个"按键钩子"，只认 ⌘V：在 ⌘V 送到软件之前把剪贴板换成下一条，然后照常放行。
/// 钩子是"拦得住"的那种（要辅助功能权限，你已经开过），所以一定是先换好剪贴板、软件才收到 ⌘V。
/// 贴完或结束：摘掉钩子，剪贴板换回开始之前的内容。只在开着时碰 ⌘V，结束就完全不碰。
/// 台阶 23：开着"贴完按 Tab"时，每贴一条 MacKit 接着替你按一下 Tab，跳到下一个格子
@MainActor
final class PasteQueueController {
    private(set) var queue = PasteQueue<UUID>()
    private(set) var isActive = false
    private let store: ClipboardStore
    let pasteboard: NSPasteboard
    /// 自检时 false：不挂真的钩子、不显示小条
    private let live: Bool
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// 开始之前剪贴板里的东西，结束时放回去
    private var saved: [[(type: String, data: Data)]]?
    let bar: PasteQueueBar
    /// 按 ⌘V 之前先让剪贴板历史看一眼（刚复制、还没被记下的那段也能排进来）
    var beforePaste: (() -> Void)?
    var onChange: (() -> Void)?

    init(store: ClipboardStore, pasteboard: NSPasteboard = .general, live: Bool = true) {
        self.store = store
        self.pasteboard = pasteboard
        self.live = live
        bar = PasteQueueBar()
        bar.onEnd = { [weak self] in self?.finish() }
    }

    var taken: Int { queue.next }
    /// 替你按过几次 Tab（自检里数这个，不真按）
    private(set) var tabRequests = 0

    /// 开始。items 是小窗口里 ⌘ 点选好的几条；空 = 等你接着复制
    @discardableResult
    func start(with items: [ClipboardItem] = []) -> Bool {
        if isActive { finish() }
        if live {
            guard AXIsProcessTrusted() else {
                Toast.showActions("连续粘贴要用\u{201C}辅助功能\u{201D}权限（在你按 ⌘V 时换成下一条）", actions: [
                    ("去打开", { ClipboardPaster.requestAccessibility(); ClipboardPaster.openAccessibilitySettings() }),
                ])
                return false
            }
            guard installTap() else {
                Toast.show("连续粘贴没能开始：系统不让挂按键钩子", seconds: 3)
                return false
            }
        }
        saved = Self.snapshot(of: pasteboard)
        queue = PasteQueue(items.map(\.id))
        isActive = true
        if live { bar.show() }
        refresh()
        Log.app.notice("paste queue started with \(items.count) items")
        return true
    }

    /// 剪贴板历史刚记下一条：还没开始贴就排到队尾
    func didCopy(_ item: ClipboardItem) {
        guard isActive, queue.append(item.id) else { return }
        refresh()
    }

    /// 你按了 ⌘V（钩子里调，自检里直接调）：把剪贴板换成下一条。返回换没换
    @discardableResult
    func willPaste() -> Bool {
        guard isActive else { return false }
        beforePaste?()
        if queue.count == 0 { return false }                   // 还没排东西：照常贴现在剪贴板里的
        // 排着的那条要是已经从历史里删掉了，就跳过它贴下一条
        var item: ClipboardItem?
        while item == nil, let id = queue.take() { item = store.items.first { $0.id == id } }
        guard let item else {
            finishSoon()
            return false
        }
        ClipboardPaster.write(item, plainText: false, store: store, to: pasteboard)
        refresh()
        if queue.isFinished { finishSoon() }
        return true
    }

    /// 钩子里看到 ⌘V：在 MacKit 自己的窗口里不算；换好下一条后，开着"贴完按 Tab"就等软件贴好，再替你按一下 Tab
    func handleCommandV(frontIsMe: Bool) {
        guard !frontIsMe, willPaste(), Settings.pasteQueueTab else { return }
        tabRequests += 1
        guard live else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            Self.pressTab()
        }
    }

    /// 按一下 Tab：明确不带修饰键（你可能还按着 ⌘，不然就成了 ⌘Tab 切软件）
    static func pressTab() {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Tab), keyDown: down)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
    }

    /// 最后一条交给软件之后再收尾，免得软件还没读剪贴板就被换回去了
    private func finishSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if self.isActive && self.queue.isFinished { self.finish() }
        }
    }

    /// 结束：摘钩子、剪贴板换回开始之前的、小条收起
    func finish() {
        guard isActive else { return }
        isActive = false
        removeTap()
        if let saved { Self.restore(saved, to: pasteboard) }
        saved = nil
        bar.close()
        Log.app.notice("paste queue finished after \(self.queue.next) of \(self.queue.count)")
        onChange?()
    }

    var statusText: String {
        let upcoming = queue.upcoming.flatMap { id in store.items.first { $0.id == id } }
        return ClipboardText.queueStatus(taken: queue.next, count: queue.count, upcoming: upcoming?.displayTitle)
    }

    private func refresh() {
        bar.update(statusText)
        onChange?()
    }

    // MARK: 剪贴板存一份、放回去

    static func snapshot(of pb: NSPasteboard) -> [[(type: String, data: Data)]] {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } } }
    }

    /// 放回去时打上 MacKit 的标记，剪贴板历史不会再记一遍
    static func restore(_ items: [[(type: String, data: Data)]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objects = items.enumerated().map { i, entries -> NSPasteboardItem in
            let p = NSPasteboardItem()
            for e in entries { p.setData(e.data, forType: NSPasteboard.PasteboardType(e.type)) }
            if i == 0 { p.setData(Data(), forType: ClipboardReader.restoreMarker) }
            return p
        }
        pb.writeObjects(objects)
    }

    // MARK: 按键钩子

    private func installTap() -> Bool {
        removeTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: pasteQueueTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }
}

/// 钩子的回调：只看 ⌘V（不带别的修饰键、不是按住不放的连发），别的键原样放行
private func pasteQueueTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<PasteQueueController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V),
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    guard flags.contains(.maskCommand), !flags.contains(.maskShift), !flags.contains(.maskAlternate),
          !flags.contains(.maskControl) else { return Unmanaged.passUnretained(event) }
    MainActor.assumeIsolated {
        // 在 MacKit 自己的窗口里（比如剪贴板搜索框）按 ⌘V 不算
        controller.handleCommandV(frontIsMe: NSWorkspace.shared.frontmostApplication?.processIdentifier
                                  == ProcessInfo.processInfo.processIdentifier)
    }
    return Unmanaged.passUnretained(event)
}

/// 屏幕右上角的小条："连续粘贴 2 / 5　下一条：张三…　贴完按 Tab　结束"
@MainActor
final class PasteQueueBar {
    let panel: NSPanel
    let label = Theme.label("")
    var onEnd: (() -> Void)?
    /// "贴完按 Tab"开关（台阶 23）：亮着 = 开；记住上次的选择
    private(set) var tabButton: ToolbarButton!

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let icon = NSImageView(image: NSImage(systemSymbolName: "list.number", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        let end = ToolbarButton(title: "结束", tip: "结束连续粘贴，剪贴板换回原来的", style: .secondary) { [weak self] in self?.onEnd?() }
        tabButton = ToolbarButton(symbol: "arrow.right.to.line", title: "贴完按 Tab",
                                  tip: "开着时：每贴一条，MacKit 接着替你按一下 Tab，跳到下一个格子") { [weak self] in self?.toggleTab() }
        let row = Theme.row([icon, label, tabButton, end], spacing: 8, insets: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 6))
        panel.contentView = Theme.bar(containing: row)
        refreshTabButton()
    }

    func toggleTab() {
        Settings.pasteQueueTab.toggle()
        refreshTabButton()
    }

    func refreshTabButton() {
        tabButton.isSelectedLook = Settings.pasteQueueTab
    }

    func update(_ text: String) {
        label.stringValue = text
        guard let row = (panel.contentView?.subviews.first as? NSStackView) else { return }
        panel.setContentSize(row.fittingSize)
        place()
    }

    func show() {
        refreshTabButton()                                  // 设置窗口里可能改过
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        guard let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12))
    }

    func close() { panel.orderOut(nil) }
}
