import AppKit

/// 一次长截图：框四周红色虚线、下面控制条、旁边预览条；你滚（或 MacKit 替你滚），它一边拍一边拼
@MainActor
final class LongShotSession {
    private(set) static weak var active: LongShotSession?

    /// 拼好的长图；nil = 取消了 / 出错了
    var onFinish: ((CGImage?) -> Void)?
    let region: ScreenRegion
    let scale: CGFloat
    let border: RecordingBorderWindow
    let bar = LongShotControlBar()
    let preview: LongShotPreview
    let capture: LongShotCapture
    private(set) var scroller: AutoScroller?
    private var hotKeys: [UInt32] = []
    private(set) var finished = false
    private var lastProgress: LongShotProgress?
    // 自动滚动：什么时候开始的、上次接上新内容是什么时候、方向对不对
    private var autoStartedAt = Date()
    private var lastAppendAt = Date()
    private var autoConfirmed = false
    private var autoFlipped = false
    private var watchdog: Timer?
    /// 方向在之前的长截图里已经确认过
    private static var directionConfirmed = false

    init(region: ScreenRegion, maxHeight: Int = 30000) {
        self.region = region
        let screen = NSScreen.screens.first { $0.displayID == region.displayID }
        scale = screen?.backingScaleFactor ?? 2
        border = RecordingBorderWindow(region: region.globalRect, screenFrame: region.screenFrame, adjustable: false,
                                       color: Theme.accent)
        let visible = screen?.visibleFrame ?? region.screenFrame
        preview = LongShotPreview(frame: LongShotGeometry.previewFrame(region: region.globalRect, visible: visible,
                                                                      width: LongShotPreview.width))
        capture = LongShotCapture(maxHeight: maxHeight)
        bar.onAuto = { [weak self] in self?.toggleAuto() }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onDone = { [weak self] in self?.finish() }
        capture.onProgress = { [weak self] p in self?.handle(p) }
        capture.onError = { [weak self] _ in self?.finish() }
    }

    var isAutoScrolling: Bool { scroller?.isRunning == true }

    /// 摆好红框、控制条、预览条，开始拍。startCapture = false：只摆界面不拍（自检用）
    func begin(startCapture: Bool = true, showWindows: Bool = true) {
        Self.active = self
        if showWindows {
            border.show()
            bar.show(near: region.globalRect, on: NSScreen.screens.first { $0.displayID == region.displayID })
            preview.show()
            registerKeys()
        }
        guard startCapture else { return }
        Task { @MainActor in
            do {
                try await capture.start(region: region)
            } catch {
                fail(error)
            }
        }
    }

    /// 你不在 MacKit 里（要滚的是别的软件），所以回车、Esc 临时注册成全局快捷键，长截图结束就还回去
    private func registerKeys() {
        let esc = HotKeyCombo(keyCode: 53, carbonModifiers: 0, display: "Esc", menuKey: "", menuModifiers: [], note: "")
        let ret = HotKeyCombo(keyCode: 36, carbonModifiers: 0, display: "↩", menuKey: "", menuModifiers: [], note: "")
        let enter = HotKeyCombo(keyCode: 76, carbonModifiers: 0, display: "⌤", menuKey: "", menuModifiers: [], note: "")
        if let id = HotKeyCenter.shared.register(esc, action: { [weak self] in self?.cancel() }) { hotKeys.append(id) }
        for combo in [ret, enter] {
            if let id = HotKeyCenter.shared.register(combo, action: { [weak self] in self?.finish() }) { hotKeys.append(id) }
        }
    }

    // MARK: 进展

    func handle(_ p: LongShotProgress) {
        guard !finished else { return }
        lastProgress = p
        if let thumb = p.thumb { preview.update(thumb) }
        switch p.event {
        case .first:
            break
        case .appended:
            lastAppendAt = Date()
            if isAutoScrolling {
                autoConfirmed = true
                Self.directionConfirmed = true
            }
            bar.setStatus(LongShotGeometry.progressText(totalHeight: p.totalHeight, screens: p.screens))
        case .full:
            stopAuto()
            bar.setStatus("到 3 万像素上限了，点完成", warning: true)
        case .lost:
            if isAutoScrolling {
                stopAuto()
                bar.setStatus("自动滚动跟丢了：往回滚一点，再点自动滚动", warning: true)
            } else {
                bar.setStatus("对不上了：往回滚一点，滚慢一点", warning: true)
            }
        case .up(let k):
            // 自动滚动刚开始就往回走：方向反了，换过来
            if isAutoScrolling, !autoConfirmed, !autoFlipped {
                flipAuto()
            } else if k > 0, !bar.isWarning {
                bar.setStatus(LongShotGeometry.progressText(totalHeight: p.totalHeight, screens: p.screens))
            }
        case .same, .blank:
            break
        }
    }

    // MARK: 自动滚动

    func toggleAuto() {
        guard !finished else { return }
        if isAutoScrolling {
            stopAuto()
            bar.setStatus(lastProgressText)
            return
        }
        guard AutoScroller.hasPermission else {
            Toast.showActions("自动滚动要用\u{201C}辅助功能\u{201D}权限（替你滚滚轮）", actions: [
                ("去打开", { ClipboardPaster.requestAccessibility(); ClipboardPaster.openAccessibilitySettings() }),
            ])
            return
        }
        guard lastProgress?.event != .full else { return }
        let s = AutoScroller(region: region.globalRect)
        s.onMouseMoved = { [weak self] in
            guard let self else { return }
            self.stopAuto()
            self.bar.setStatus("你动了鼠标，自动滚动停了")
        }
        scroller = s
        autoStartedAt = Date()
        lastAppendAt = Date()
        autoConfirmed = false
        autoFlipped = false
        s.start()
        bar.setAutoScrolling(true)
        bar.setStatus("正在自动滚动，到底自动停　·　动一下鼠标就停")
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAuto() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
        Log.capture.notice("long shot auto scroll on")
    }

    private func flipAuto() {
        autoFlipped = true
        scroller?.flipDirection()
        autoStartedAt = Date()
        lastAppendAt = Date()
        Log.capture.notice("long shot auto scroll flipped direction")
    }

    /// 一直没有新内容：刚开始就没动 = 方向可能反了，换一次；之后还没动 = 到底了
    private func checkAuto() {
        guard isAutoScrolling else { return }
        let now = Date()
        if !autoConfirmed, !autoFlipped, !Self.directionConfirmed, now.timeIntervalSince(autoStartedAt) > 0.8 {
            flipAuto()
            return
        }
        if now.timeIntervalSince(lastAppendAt) > 2 {
            stopAuto()
            bar.setStatus(autoConfirmed || Self.directionConfirmed ? "滚到底了，点完成（或者自己再滚滚）" : "滚不动：自己滚一下试试",
                          warning: !(autoConfirmed || Self.directionConfirmed))
        }
    }

    private func stopAuto() {
        scroller?.stop()
        scroller = nil
        watchdog?.invalidate()
        watchdog = nil
        bar.setAutoScrolling(false)
    }

    private var lastProgressText: String {
        guard let p = lastProgress, p.totalHeight > 0, p.event != .first || p.screens > 1.01 else { return LongShotControlBar.startText }
        return LongShotGeometry.progressText(totalHeight: p.totalHeight, screens: p.screens)
    }

    // MARK: 结束

    func finish() {
        guard !finished else { return }
        finished = true
        stopAuto()
        bar.setStatus("正在拼…")
        capture.finish { [weak self] image in
            guard let self else { return }
            self.tearDown()
            Log.capture.notice("long shot finished \(image?.width ?? 0)x\(image?.height ?? 0)")
            self.onFinish?(image)
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        stopAuto()
        capture.cancel()
        tearDown()
        Log.capture.notice("long shot cancelled")
        onFinish?(nil)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        stopAuto()
        capture.cancel()
        tearDown()
        let ns = error as NSError
        Log.capture.error("long shot failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
        if !ScreenPermission.isGranted { ScreenPermission.showGuide() } else { Toast.show("长截图失败：\(ns.localizedDescription)", seconds: 3) }
        onFinish?(nil)
    }

    private func tearDown() {
        for id in hotKeys { HotKeyCenter.shared.unregister(id) }
        hotKeys.removeAll()
        border.close()
        bar.close()
        preview.close()
        if Self.active === self { Self.active = nil }
    }
}

/// 长截图积木：从截图工具栏点"长截图"或菜单里"长截图"开始。拼好后复制到剪贴板，同时存成 PNG
@MainActor
final class LongShotTool: ToolModule {
    /// 提示里点"钉成贴图"：交给贴图积木（AppDelegate 里接上）
    var onPin: ((CGImage, NSSize) -> Void)?
    private(set) var session: LongShotSession?
    /// 长截图上标注的窗口（台阶 20）
    private(set) var annotateWindow: LongShotAnnotateWindow?
    /// 自检时 false：标完不弹提示条
    var showsToast = true

    func activate() {}

    /// 菜单项放在截图那一组里（ScreenshotTool.menuItems）
    func menuItems() -> [NSMenuItem] { [] }

    func start(_ region: ScreenRegion) {
        guard session == nil, LongShotSession.active == nil else { return }
        guard region.viewRect.width >= 20, region.viewRect.height >= 40 else {
            Toast.show("框太小了：长截图至少要 20×40 点")
            return
        }
        let s = LongShotSession(region: region)
        let scale = s.scale
        s.onFinish = { [weak self] image in
            guard let self else { return }
            self.session = nil
            if let image { self.deliver(image, scale: scale) }
        }
        session = s
        s.begin()
    }

    private func deliver(_ image: CGImage, scale: CGFloat) {
        guard let out = Self.output(image, scale: scale, pasteboard: .general, folder: Settings.saveFolder) else {
            Toast.show("长截图失败：图片编码出错")
            return
        }
        let size = out.pointSize
        var actions: [(title: String, run: @MainActor () -> Void)] = []
        if let url = out.url { actions.append(("打开看看", { NSWorkspace.shared.open(url) })) }
        actions.append(("标注", { [weak self] in self?.annotate(image, pointSize: size) }))         // 台阶 20：点了才打开（拍板）
        actions.append(("钉成贴图", { [weak self] in self?.onPin?(image, size) }))
        let saved = out.url != nil ? "并保存" : "，但保存失败：\(out.saveError ?? "")"
        Toast.showActions("✓ 长截图已复制\(saved)　\(image.width)×\(image.height)", actions: actions)
    }

    /// 打开长截图标注窗口；present = false 只给自检用（不显示）
    @discardableResult
    func annotate(_ image: CGImage, pointSize: NSSize, present: Bool = true,
                  pasteboard: NSPasteboard = .general, folder: URL? = nil) -> LongShotAnnotateWindow {
        annotateWindow?.window.close()
        let w = LongShotAnnotateWindow(image: image, pointSize: pointSize)
        w.onDone = { [weak self] annotated, size in
            self?.deliverAnnotated(annotated, size: size, pasteboard: pasteboard, folder: folder ?? Settings.saveFolder)
        }
        w.onClose = { [weak self, weak w] in if self?.annotateWindow === w { self?.annotateWindow = nil } }
        annotateWindow = w
        Log.capture.notice("long shot annotate \(image.width)x\(image.height)")
        if present { w.show() }
        return w
    }

    /// 标完：复制带标注的那张，另存一张新的 PNG（原来那张留着，拍板）
    private(set) var lastAnnotatedURL: URL?

    private func deliverAnnotated(_ image: CGImage, size: CGSize, pasteboard: NSPasteboard, folder: URL) {
        let scale = CGFloat(image.width) / max(size.width, 1)
        guard let out = Self.output(image, scale: scale, pasteboard: pasteboard, folder: folder) else {
            if showsToast { Toast.show("长截图标注失败：图片编码出错") }
            return
        }
        lastAnnotatedURL = out.url
        guard showsToast else { return }
        Toast.show(out.url != nil ? "✓ 标好了：已复制，另存了一张新的（原来那张还在）" : "✓ 标好了：已复制（保存失败：\(out.saveError ?? "")）",
                   seconds: 3)
    }

    struct Output {
        let pointSize: NSSize
        let url: URL?
        let saveError: String?
    }

    /// 复制到剪贴板 + 存 PNG。长图很大时剪贴板里只放 PNG（TIFF 不压缩，几十屏能有好几百 MB）
    static func output(_ image: CGImage, scale: CGFloat, pasteboard: NSPasteboard, folder: URL) -> Output? {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = ImageOutput.pngData(of: image, pointSize: size) else { return nil }
        ImageOutput.copyToClipboard(image, pointSize: size, png: png, to: pasteboard,
                                    includeTIFF: image.width * image.height <= 16_000_000)
        do {
            let url = try ImageOutput.save(png: png, to: folder)
            Log.capture.notice("long shot saved \(url.path, privacy: .public)")
            return Output(pointSize: size, url: url, saveError: nil)
        } catch {
            Log.capture.error("long shot save failed: \(error.localizedDescription, privacy: .public)")
            return Output(pointSize: size, url: nil, saveError: error.localizedDescription)
        }
    }
}
