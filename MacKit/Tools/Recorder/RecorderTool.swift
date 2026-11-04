import AppKit
import AVFoundation

/// 录屏积木：⌘4 选区域（框选 / 单击窗口 / 桌面单击整屏）→ 控制条（声音、录多久自动停、几点开始）→ 倒数 → 录制
/// （能暂停 / 继续）→ 再按 ⌘4 或点小条上的停止 → 存成 mp4 → 提示里能预览剪辑、存成 GIF
@MainActor
final class RecorderTool: ToolModule {
    enum State: Equatable {
        case idle
        case choosing
        case ready(RecordTarget)
        case scheduled(RecordTarget, Date)      // 等定时开始
        case countingDown
        case recording
        case pausing                            // 正在把这一段收尾
        case paused
        case stopping
    }

    /// 一次录制。暂停会把它分成好几段，停止后拼成一个文件
    final class Job {
        let target: RecordTarget
        let options: RecordOptions
        let autoStopMinutes: Int
        let tempDirectory: URL
        var segments: [URL] = []
        var recordedBefore: TimeInterval = 0     // 已经收尾的那几段一共多长
        var recorder: ScreenRecorder?
        var lastError: Error?

        init(target: RecordTarget, options: RecordOptions, autoStopMinutes: Int) {
            self.target = target
            self.options = options
            self.autoStopMinutes = autoStopMinutes
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mackit-recording-\(UUID().uuidString)", isDirectory: true)
        }

        /// 录了多久（暂停的不算）
        @MainActor var elapsed: TimeInterval { recordedBefore + (recorder?.duration ?? 0) }
        var nextSegmentURL: URL { tempDirectory.appendingPathComponent("part-\(segments.count + 1).mp4") }
    }

    private(set) var state: State = .idle
    /// 菜单栏图标显示什么：nil = 平常的扳手；有字 = 红点加时长（AppDelegate 里接上）
    var onIndicator: ((String?) -> Void)?
    private(set) var hotKeyRegistered = false
    private var hotKeyID: UInt32?
    private var selection: SelectionSession?
    private(set) var controlBar: RecordingControlBar?
    private var border: RecordingBorderWindow?
    private var countdown: CountdownWindow?
    /// 录制中挂在区域旁边的小条（2026-11-04 验收：只有菜单栏红点，常常不知道在不在录）
    private(set) var hud: RecordingHUD?
    private(set) var job: Job?
    private var ticker: Timer?
    private(set) var lastRecording: URL?
    private var preview: RecordingPreviewWindow?
    /// 第二批：摄像头画中画、按键牌子
    private(set) var camera: CameraBubble?
    private var keyCaster: KeyCaster?

    func activate() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = HotKeyCenter.shared.register(Settings.recordHotKey) { [weak self] in self?.hotKeyPressed() }
        hotKeyRegistered = hotKeyID != nil
    }

    /// ⌘4：空闲时选区域；控制条出来后 = 开始；等定时开始时 = 现在就开始；录制中或暂停中 = 停止
    func hotKeyPressed() {
        switch state {
        case .idle: choose()
        case .ready(let target): startFromBar(target)
        case .scheduled(let target, _): beginCountdown(target)
        case .recording, .paused: stop()
        case .choosing, .countingDown, .pausing, .stopping: break
        }
    }

    // MARK: 选区域、控制条

    func choose(delay: Double = 0) {
        guard state == .idle, SelectionSession.active == nil, MeasureSession.active == nil else { return }
        guard ScreenPermission.readyToTry() else { return }
        state = .choosing
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let windows = WindowList.current()
            do {
                let frozen = try await ScreenCapturer.capture()
                guard !frozen.isEmpty else { self.reset(); return }
                let session = SelectionSession(screens: frozen, windowFrames: windows.map(\.frame), quickMode: false,
                                               windowIDs: windows.map(\.id), purpose: .record)
                session.onFinish = { [weak self] outcome in
                    self?.selection = nil
                    if case .record(let target) = outcome { self?.showControlBar(for: target) } else { self?.reset() }
                }
                self.selection = session
                session.begin()
            } catch {
                Log.capture.error("record: capture for selection failed \(error.localizedDescription, privacy: .public)")
                self.reset()
                ScreenPermission.showGuide()
            }
        }
    }

    /// 选好区域后出控制条（自检也直接调它）
    func showControlBar(for target: RecordTarget, present: Bool = true) {
        state = .ready(target)
        var isWindow = false
        if case .window = target { isWindow = true }
        let bar = RecordingControlBar(systemAudio: Settings.recordSystemAudio, microphone: Settings.recordMicrophone,
                                      showClicks: Settings.recordShowClicks, showKeys: Settings.recordShowKeys,
                                      camera: Settings.recordCamera, windowTarget: isWindow)
        bar.onStart = { [weak self] in self?.startFromBar(target) }
        bar.onCancel = { [weak self] in self?.reset() }
        bar.onCameraChange = { [weak self] on in
            if on { self?.showCamera(for: target) } else { self?.hideCamera() }
        }
        controlBar = bar
        if present, Settings.recordCamera { showCamera(for: target) }    // 上次开着：录之前就出来，好摆位置
        if present, case .region(_, let screenFrame, _) = target {
            // 开录之前红框能调大小、挪位置，控制条跟着走
            let b = RecordingBorderWindow(region: target.globalFrame, screenFrame: screenFrame, adjustable: true)
            b.onChange = { [weak self, weak bar] region in
                bar?.move(near: region, on: Self.screen(containing: region))
                _ = self
            }
            b.show()
            border = b
        }
        if present { bar.show(near: target.globalFrame, on: Self.screen(containing: target.globalFrame)) }
        Log.capture.notice("record: target chosen \(target.title, privacy: .public)")
    }

    /// 用户调过红框：按调好的框录
    static func adjusted(_ target: RecordTarget, to region: CGRect?) -> RecordTarget {
        guard let region, case .region(let id, let screenFrame, _) = target else { return target }
        return .region(id: id, screenFrame: screenFrame,
                       viewRect: region.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
    }

    /// 控制条上点"开始录制"：设了几点开始就先等着，否则马上倒数。从这时起红框锁定
    func startFromBar(_ chosen: RecordTarget, present: Bool = true) {
        guard case .ready = state else { return }
        let target = Self.adjusted(chosen, to: border?.region)
        border?.setAdjustable(false)
        if let at = controlBar?.startAt, at > Date() {
            state = .scheduled(target, at)
            pendingOptions = currentOptions()
            pendingAutoStop = controlBar?.autoStopMinutes ?? 0
            controlBar?.close()
            if present {
                let h = makeHUD(for: target, options: pendingOptions!)
                h.setMode(.waiting)
                updateWaitingText(at)
            }
            startTicker()
            Log.capture.notice("record: scheduled")
        } else {
            beginCountdown(target)
        }
    }

    private var pendingOptions: RecordOptions?
    private var pendingAutoStop = 0
    /// 暂停的那一段还在收尾时就点了"继续"：收尾完自动接着录
    private var resumeWhenPaused = false

    private func currentOptions() -> RecordOptions {
        RecordOptions(systemAudio: controlBar?.systemAudio ?? Settings.recordSystemAudio,
                      microphone: controlBar?.microphone ?? Settings.recordMicrophone,
                      quality: Settings.recordQuality,
                      showClicks: controlBar?.showClicks ?? Settings.recordShowClicks,
                      showKeys: controlBar?.showKeys ?? Settings.recordShowKeys)
    }

    // MARK: 摄像头、按键

    private func showCamera(for target: RecordTarget) {
        guard camera == nil else { return }
        let visible = Self.screen(containing: target.globalFrame)?.visibleFrame ?? target.globalFrame
        let bubble = CameraBubble(side: RecordGeometry.clampCameraSide(Settings.cameraSide), rounded: Settings.cameraRounded)
        bubble.place(RecordGeometry.cameraFrame(side: bubble.side, target: target.globalFrame, visible: visible))
        bubble.onTurnOff = { [weak self] in
            self?.controlBar?.setCamera(false, remember: true)
            self?.hideCamera()
        }
        camera = bubble
        Task { @MainActor in
            if !(await bubble.start()) {
                self.hideCamera()
                self.controlBar?.setCamera(false, remember: true)
                Toast.show("摄像头没有权限：去「系统设置 → 隐私与安全性 → 摄像头」打开 MacKit", seconds: 5)
            }
        }
    }

    private func hideCamera() {
        camera?.close()
        camera = nil
    }

    // MARK: 倒数、开始

    private func beginCountdown(_ target: RecordTarget) {
        switch state {
        case .ready, .scheduled: break
        default: return
        }
        var options = pendingOptions ?? currentOptions()
        let autoStop = pendingOptions != nil ? pendingAutoStop : (controlBar?.autoStopMinutes ?? 0)
        pendingOptions = nil
        controlBar?.close()
        controlBar = nil
        hud?.close()
        hud = nil
        ticker?.invalidate()
        state = .countingDown
        Task { @MainActor in
            if options.microphone, !(await Self.microphoneAllowed()) {
                options.microphone = false
                Toast.show("麦克风没有权限，这次不录你的声音。去「系统设置 → 隐私与安全性 → 麦克风」打开 MacKit", seconds: 4)
            }
            let cd = CountdownWindow(center: CGPoint(x: target.globalFrame.midX, y: target.globalFrame.midY))
            countdown = cd
            for n in [3, 2, 1] {
                cd.show(n)
                try? await Task.sleep(for: .seconds(1))
                guard self.state == .countingDown else { cd.close(); return }       // 倒数时被取消
            }
            cd.close()
            countdown = nil
            let job = Job(target: target, options: options, autoStopMinutes: autoStop)
            try? FileManager.default.createDirectory(at: job.tempDirectory, withIntermediateDirectories: true)
            self.job = job
            _ = self.makeHUD(for: target, options: options)
            if options.showKeys {
                let caster = KeyCaster()
                var isFull = false
                if case .display = target { isFull = true }
                caster.start(target: target.globalFrame, fullScreen: isFull)
                self.keyCaster = caster
            }
            await self.startSegment()
        }
    }

    private func makeHUD(for target: RecordTarget, options: RecordOptions) -> RecordingHUD {
        if let hud { return hud }
        let h = RecordingHUD(systemAudio: options.systemAudio, microphone: options.microphone)
        h.onStop = { [weak self] in self?.stop() }
        h.onPause = { [weak self] in self?.pause() }
        h.onResume = { [weak self] in self?.resume() }
        h.onStartNow = { [weak self] in
            if case .scheduled(let t, _) = self?.state { self?.beginCountdown(t) }
        }
        h.onCancel = { [weak self] in self?.reset() }
        var isFullScreen = false
        if case .display = target { isFullScreen = true }
        h.show(near: target.globalFrame, on: Self.screen(containing: target.globalFrame), fullScreen: isFullScreen)
        hud = h
        return h
    }

    /// 开始录新的一段（第一次开始、暂停后继续都走这里）
    private func startSegment() async {
        guard let job else { return }
        let recorder = ScreenRecorder(url: job.nextSegmentURL)
        recorder.onFinished = { [weak self, weak recorder] result in
            guard let self, let recorder else { return }
            self.segmentFinished(recorder, result)
        }
        job.recorder = recorder
        do {
            // 小条和红框从画面里排除
            let excluded = [hud?.windowNumber, border?.windowNumber].compactMap { $0 }
            try await recorder.start(target: job.target, options: job.options, excluding: excluded)
            state = .recording
            hud?.setMode(.recording)
            startTicker()
        } catch {
            Log.capture.error("record: segment start failed \(error.localizedDescription, privacy: .public)")
            job.recorder = nil
            if job.segments.isEmpty {
                Toast.show("录屏没能开始：\(error.localizedDescription)", seconds: 4)
                reset()
            } else {
                job.lastError = error                // 继续失败：把已经录到的存下来
                state = .stopping
                finalize()
            }
        }
    }

    // MARK: 暂停、继续、停止

    func pause() {
        guard state == .recording, let recorder = job?.recorder else { return }
        state = .pausing
        hud?.setMode(.paused)
        hud?.update("已暂停 " + RecordGeometry.durationText(job?.elapsed ?? 0))
        onIndicator?("⏸ " + RecordGeometry.durationText(job?.elapsed ?? 0))
        Task { @MainActor in await recorder.stop() }
    }

    func resume() {
        if state == .pausing { resumeWhenPaused = true; return }
        guard state == .paused else { return }
        state = .countingDown                        // 防止连点；开始成功后变回 recording
        Task { @MainActor in await self.startSegment() }
    }

    func stop() {
        switch state {
        case .recording:
            guard let recorder = job?.recorder else { return }
            state = .stopping
            showSaving()
            Task { @MainActor in await recorder.stop() }
        case .paused:
            state = .stopping
            showSaving()
            finalize()
        case .pausing:                               // 这一段收尾完就直接拼成文件
            resumeWhenPaused = false
            state = .stopping
            showSaving()
        case .ready, .scheduled, .countingDown:
            reset()                                  // 还没开始录：等于取消
        default:
            break
        }
    }

    private func showSaving() {
        ticker?.invalidate()
        onIndicator?("保存中…")
        hud?.setMode(.saving)
        hud?.update("保存中…")
    }

    /// 一段收尾了：记下来；暂停中 → 等继续；停止中（或者录制流自己断了）→ 拼成最终文件
    private func segmentFinished(_ recorder: ScreenRecorder, _ result: Result<URL, Error>) {
        guard let job, job.recorder === recorder else { return }
        job.recorder = nil
        job.recordedBefore += recorder.duration
        let size = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int) ?? 0
        if size > 0 { job.segments.append(recorder.url) }
        if case .failure(let error) = result { job.lastError = error }
        switch state {
        case .pausing:
            state = .paused
            ticker?.invalidate()
            if resumeWhenPaused {
                resumeWhenPaused = false
                resume()
            }
        case .recording:                                 // 录着录着断了（窗口关了、磁盘满了）
            state = .stopping
            showSaving()
            finalize()
        default:
            finalize()
        }
    }

    /// 几段 → 一个 mp4，放进保存位置
    private func finalize() {
        guard let job else { reset(); return }
        let seconds = job.recordedBefore
        let error = job.lastError
        let parts = job.segments
        Task { @MainActor in
            let folder = Settings.recordFolder
            let output = folder.appendingPathComponent(RecordGeometry.fileName(for: Date()))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if parts.count == 1 {
                    try FileManager.default.moveItem(at: parts[0], to: output)
                } else {
                    try await VideoTools.concatenate(parts, to: output)
                }
                try? FileManager.default.removeItem(at: job.tempDirectory)
                self.reset()
                self.done(output, seconds: seconds, partCount: parts.count, error: error)
            } catch {
                Log.capture.error("record: finalize failed \(error.localizedDescription, privacy: .public)")
                self.reset()
                Toast.show(parts.isEmpty ? "录屏失败：没有录到内容" : "录屏保存失败：\(error.localizedDescription)", seconds: 5)
            }
        }
    }

    private func done(_ url: URL, seconds: TimeInterval, partCount: Int, error: Error?) {
        lastRecording = url
        Log.capture.notice("record: saved \(url.lastPathComponent, privacy: .public), \(partCount) part(s)")
        if Settings.recordOpenPreview {
            openPreview(url)
            return
        }
        let reason = error.map { "录制中断（\($0.localizedDescription)），已保存录到的部分" } ?? "✓ 录屏已保存"
        Toast.showActions("\(reason)（\(RecordGeometry.durationText(seconds))）", actions: [
            ("预览剪辑", { [weak self] in self?.openPreview(url) }),
            ("存成 GIF", { [weak self] in self?.makeGIF(from: url, range: nil) }),
            ("在访达中显示", { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
        ])
    }

    // MARK: 计时

    private func startTicker() {
        ticker?.invalidate()
        tick()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        switch state {
        case .recording:
            guard let job else { return }
            let text = RecordGeometry.durationText(job.elapsed)
            onIndicator?(text)
            hud?.update(text + (job.autoStopMinutes > 0 ? " / \(job.autoStopMinutes) 分钟" : ""))
            if RecordSchedule.shouldAutoStop(recorded: job.elapsed, limitMinutes: job.autoStopMinutes) {
                Log.capture.notice("record: auto stop after \(job.autoStopMinutes) min")
                stop()
            }
        case .scheduled(let target, let at):
            if Date() >= at {
                beginCountdown(target)
            } else {
                updateWaitingText(at)
            }
        default:
            break
        }
    }

    private func updateWaitingText(_ at: Date) {
        let left = RecordGeometry.durationText(at.timeIntervalSinceNow.rounded(.up))
        let title = RecordSchedule.startTitle(at, now: Date())
        hud?.update("\(title) · 还有 \(left)")
        onIndicator?("⏰ " + left)
    }

    /// 回到什么都没在做的状态，收起所有录屏界面
    func reset() {
        ticker?.invalidate()
        ticker = nil
        controlBar?.close()
        controlBar = nil
        countdown?.close()
        countdown = nil
        border?.close()
        border = nil
        hud?.close()
        hud = nil
        keyCaster?.stop()
        keyCaster = nil
        hideCamera()
        if let job, job.recorder == nil, state != .stopping { try? FileManager.default.removeItem(at: job.tempDirectory) }
        job = nil
        pendingOptions = nil
        resumeWhenPaused = false
        state = .idle
        onIndicator?(nil)
    }

    // MARK: 预览、GIF

    func openPreview(_ url: URL) {
        let p = RecordingPreviewWindow(url: url)
        p.onGIF = { [weak self] u, range in self?.makeGIF(from: u, range: range) }
        p.onClose = { [weak self] in
            self?.preview = nil
            if NSApp.isActive, NSApp.modalWindow == nil { NSApp.hide(nil) }
        }
        preview = p
        p.show()
    }

    /// 存成 GIF：和视频放在一起、同名。超过 30 秒先问一句
    func makeGIF(from url: URL, range: CMTimeRange?) {
        Task { @MainActor in
            var seconds = range?.duration.seconds ?? 0
            if range == nil { seconds = await VideoTools.duration(of: url) }
            if seconds > RecordSchedule.gifWarnSeconds {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "这段有 \(Int(seconds)) 秒，转成 GIF 会很大"
                alert.informativeText = "GIF 适合几秒的小动画。这么长的可能有几十 MB，微信也可能发不出去。\n想发短一点的，可以先「预览剪辑」剪短再转。"
                alert.addButton(withTitle: "还是转")
                alert.addButton(withTitle: "算了")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let output = url.deletingPathExtension().appendingPathExtension("gif")
            Toast.show("正在存成 GIF…", seconds: 120)
            do {
                let frames = try await VideoTools.makeGIF(from: url, range: range, to: output)
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                let mb = String(format: "%.1f", Double(size) / 1_048_576)
                Log.capture.notice("record: gif \(frames) frames, \(size) bytes")
                Toast.show("✓ GIF 已保存（\(mb) MB）　点这里在访达中显示", seconds: 5) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                Toast.show("GIF 没存成：\(error.localizedDescription)", seconds: 4)
            }
        }
    }

    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
    }

    // MARK: 菜单

    func menuItems() -> [NSMenuItem] {
        let combo = Settings.recordHotKey
        var items: [NSMenuItem] = []
        let elapsed = RecordGeometry.durationText(job?.elapsed ?? 0)
        switch state {
        case .recording:
            items.append(ActionMenuItem("■ 停止录制（已录 \(elapsed)）", key: combo.menuKey, modifiers: combo.menuModifiers) {
                [weak self] in self?.stop()
            })
            items.append(ActionMenuItem("⏸ 暂停") { [weak self] in self?.pause() })
        case .paused:
            items.append(ActionMenuItem("▶ 继续录制（已录 \(elapsed)）") { [weak self] in self?.resume() })
            items.append(ActionMenuItem("■ 停止录制", key: combo.menuKey, modifiers: combo.menuModifiers) { [weak self] in self?.stop() })
        case .scheduled(let target, let at):
            items.append(.info("⏰ \(RecordSchedule.startTitle(at, now: Date()))"))
            items.append(ActionMenuItem("现在就开始", key: combo.menuKey, modifiers: combo.menuModifiers) { [weak self] in
                self?.beginCountdown(target)
            })
            items.append(ActionMenuItem("取消定时录制") { [weak self] in self?.reset() })
        case .ready, .countingDown:
            items.append(ActionMenuItem("取消这次录屏") { [weak self] in self?.reset() })
        case .pausing, .stopping:
            items.append(.info("录屏处理中…"))
        case .idle, .choosing:
            items.append(ActionMenuItem("录屏（框选 / 单击窗口 / 整屏）", key: hotKeyRegistered ? combo.menuKey : "",
                                        modifiers: combo.menuModifiers) { [weak self] in self?.choose(delay: 0.2) })
        }
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo.display) 没注册上，可能被别的软件占用，换一个试试"))
        } else if let rival = combo.runningRival {
            items.append(.info("⚠︎ \(rival) 开着，它也用 \(combo.display)"))
        }

        let settingsMenu = NSMenu()
        for q in RecordQuality.allCases {
            let item = ActionMenuItem("画质：\(q.title)") { Settings.recordQuality = q }
            item.state = Settings.recordQuality == q ? .on : .off
            settingsMenu.addItem(item)
        }
        settingsMenu.addItem(.separator())
        let openPreview = ActionMenuItem("录完自动打开预览") { Settings.recordOpenPreview.toggle() }
        openPreview.state = Settings.recordOpenPreview ? .on : .off
        settingsMenu.addItem(openPreview)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(.info("保存位置：" + (Settings.recordFolder.path as NSString).abbreviatingWithTildeInPath))
        settingsMenu.addItem(ActionMenuItem("在访达中打开保存位置") {
            let folder = Settings.recordFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        })
        settingsMenu.addItem(ActionMenuItem("更改保存位置…") { Self.chooseFolder() })
        if Settings.recordFolder != Settings.defaultRecordFolder {
            settingsMenu.addItem(ActionMenuItem("恢复默认（影片/MacKit）") { Settings.recordFolder = Settings.defaultRecordFolder })
        }
        settingsMenu.addItem(.separator())
        for (index, preset) in RecordHotKeyPresets.all.enumerated() {
            let item = ActionMenuItem("快捷键 \(preset.display)　\(preset.note)") { [weak self] in
                Settings.recordHotKeyIndex = index
                self?.registerHotKey()
            }
            item.state = index == Settings.recordHotKeyIndex ? .on : .off
            settingsMenu.addItem(item)
        }
        let settingsItem = NSMenuItem(title: "录屏设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        items.append(settingsItem)

        if let last = lastRecording, state == .idle {
            let lastMenu = NSMenu()
            lastMenu.addItem(ActionMenuItem("预览剪辑") { [weak self] in self?.openPreview(last) })
            lastMenu.addItem(ActionMenuItem("存成 GIF") { [weak self] in self?.makeGIF(from: last, range: nil) })
            lastMenu.addItem(ActionMenuItem("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([last]) })
            let lastItem = NSMenuItem(title: "最近一次录屏", action: nil, keyEquivalent: "")
            lastItem.submenu = lastMenu
            items.append(lastItem)
        }
        return items
    }

    private static func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "就存这里"
        panel.directoryURL = Settings.recordFolder
        panel.begin { response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { Settings.recordFolder = url }
            }
        }
    }
}
