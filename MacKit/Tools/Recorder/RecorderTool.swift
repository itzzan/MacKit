import AppKit
import AVFoundation

/// 录屏积木：⌘4 选区域（框选 / 单击窗口 / 桌面单击整屏）→ 控制条 → 倒数 → 录制 → 再按 ⌘4 停止，存成 mp4
@MainActor
final class RecorderTool: ToolModule {
    enum State: Equatable {
        case idle
        case choosing
        case ready(RecordTarget)
        case countingDown
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    /// 菜单栏图标显示什么：nil = 平常的扳手；有字 = 红点加时长（AppDelegate 里接上）
    var onIndicator: ((String?) -> Void)?
    private(set) var hotKeyRegistered = false
    private var hotKeyID: UInt32?
    private var selection: SelectionSession?
    private var controlBar: RecordingControlBar?
    private var border: RecordingBorderWindow?
    private var countdown: CountdownWindow?
    /// 录制中挂在区域旁边的小条（2026-11-04 验收：只有菜单栏红点，常常不知道在不在录）
    private(set) var hud: RecordingHUD?
    private var recorder: ScreenRecorder?
    private var ticker: Timer?
    private(set) var lastRecording: URL?

    func activate() { registerHotKey() }

    private func registerHotKey() {
        if let id = hotKeyID { HotKeyCenter.shared.unregister(id) }
        hotKeyID = HotKeyCenter.shared.register(Settings.recordHotKey) { [weak self] in self?.hotKeyPressed() }
        hotKeyRegistered = hotKeyID != nil
    }

    /// 按一次开始选、控制条出来时再按 = 开始录、录制中按 = 停止
    func hotKeyPressed() {
        switch state {
        case .idle: choose()
        case .ready(let target): begin(target)
        case .recording: stop()
        case .choosing, .countingDown, .stopping: break
        }
    }

    // MARK: 选区域

    func choose(delay: Double = 0) {
        guard state == .idle, SelectionSession.active == nil else { return }
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

    private func showControlBar(for target: RecordTarget) {
        state = .ready(target)
        if case .region = target {
            let b = RecordingBorderWindow(region: target.globalFrame)
            b.show()
            border = b
        }
        let bar = RecordingControlBar(systemAudio: Settings.recordSystemAudio, microphone: Settings.recordMicrophone)
        bar.onStart = { [weak self] in self?.begin(target) }
        bar.onCancel = { [weak self] in self?.reset() }
        bar.show(near: target.globalFrame, on: Self.screen(containing: target.globalFrame))
        controlBar = bar
        Log.capture.notice("record: target chosen \(target.title, privacy: .public)")
    }

    // MARK: 录

    private func begin(_ target: RecordTarget) {
        guard case .ready = state else { return }
        var options = RecordOptions(systemAudio: controlBar?.systemAudio ?? Settings.recordSystemAudio,
                                    microphone: controlBar?.microphone ?? Settings.recordMicrophone,
                                    quality: Settings.recordQuality)
        controlBar?.close()
        controlBar = nil
        state = .countingDown
        Task { @MainActor in
            if options.microphone, !(await Self.microphoneAllowed()) {
                options.microphone = false
                Toast.show("麦克风没有权限，这次不录你的声音。去「系统设置 → 隐私与安全性 → 麦克风」打开 MacKit", seconds: 4)
            }
            let center = CGPoint(x: target.globalFrame.midX, y: target.globalFrame.midY)
            let cd = CountdownWindow(center: center)
            countdown = cd
            for n in [3, 2, 1] {
                cd.show(n)
                try? await Task.sleep(for: .seconds(1))
                guard self.state == .countingDown else { cd.close(); return }       // 倒数时被取消
            }
            cd.close()
            countdown = nil
            await self.startRecording(target, options: options)
        }
    }

    private func startRecording(_ target: RecordTarget, options: RecordOptions) async {
        let folder = Settings.recordFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(RecordGeometry.fileName(for: Date()))
            let r = ScreenRecorder(url: url)
            r.onFinished = { [weak self] result in self?.finished(result) }
            recorder = r
            // 小条先摆好，录制时连同红框一起从画面里排除
            let h = RecordingHUD(systemAudio: options.systemAudio, microphone: options.microphone)
            h.onStop = { [weak self] in self?.stop() }
            var isFullScreen = false
            if case .display = target { isFullScreen = true }
            h.show(near: target.globalFrame, on: Self.screen(containing: target.globalFrame), fullScreen: isFullScreen)
            hud = h
            try await r.start(target: target, options: options,
                              excluding: [h.windowNumber] + (border.map { [$0.windowNumber] } ?? []))
            state = .recording
            startTicker()
        } catch {
            Log.capture.error("record: start failed \(error.localizedDescription, privacy: .public)")
            Toast.show("录屏没能开始：\(error.localizedDescription)", seconds: 4)
            reset()
        }
    }

    func stop() {
        guard state == .recording, let recorder else { return }
        state = .stopping
        ticker?.invalidate()
        onIndicator?("保存中…")
        hud?.update("保存中…")
        Task { @MainActor in await recorder.stop() }
    }

    private func finished(_ result: Result<URL, Error>) {
        let url = recorder?.url
        let seconds = recorder?.duration ?? 0
        reset()
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        guard let url, size > 0 else {
            if case .failure(let error) = result {
                Toast.show("录屏失败：\(error.localizedDescription)", seconds: 4)
            } else {
                Toast.show("录屏失败：没有生成文件", seconds: 4)
            }
            return
        }
        lastRecording = url
        let reveal = { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        let length = RecordGeometry.durationText(seconds)
        switch result {
        case .success:
            Log.capture.notice("record: saved \(url.lastPathComponent, privacy: .public) \(size) bytes")
            Toast.show("✓ 录屏已保存（\(length)）　点这里在访达中显示", seconds: 5, action: reveal)
        case .failure(let error):
            Toast.show("录制中断：\(error.localizedDescription)。已保存录到的部分　点这里在访达中显示", seconds: 6, action: reveal)
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        onIndicator?(RecordGeometry.durationText(0))
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                let text = RecordGeometry.durationText(r.duration)
                self.onIndicator?(text)
                self.hud?.update(text)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
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
        recorder = nil
        state = .idle
        onIndicator?(nil)
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
        switch state {
        case .recording:
            items.append(ActionMenuItem("■ 停止录制（已录 \(RecordGeometry.durationText(recorder?.duration ?? 0))）",
                                        key: combo.menuKey, modifiers: combo.menuModifiers) { [weak self] in self?.stop() })
        case .ready, .countingDown:
            items.append(ActionMenuItem("取消这次录屏") { [weak self] in self?.reset() })
        case .stopping:
            items.append(.info("录屏保存中…"))
        case .idle, .choosing:
            items.append(ActionMenuItem("录屏（框选 / 单击窗口 / 整屏）", key: hotKeyRegistered ? combo.menuKey : "",
                                        modifiers: combo.menuModifiers) { [weak self] in self?.choose(delay: 0.2) })
        }
        if !hotKeyRegistered {
            items.append(.info("⚠︎ 快捷键 \(combo.display) 没注册上，可能被别的软件占用，换一个试试"))
        } else if let rival = combo.runningRival {
            items.append(.info("⚠︎ \(rival) 开着，它也用 \(combo.display)"))
        }

        let qualityMenu = NSMenu()
        for q in RecordQuality.allCases {
            let item = ActionMenuItem(q.title) { Settings.recordQuality = q }
            item.state = Settings.recordQuality == q ? .on : .off
            qualityMenu.addItem(item)
        }
        let qualityItem = NSMenuItem(title: "录屏画质", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        items.append(qualityItem)

        let folderMenu = NSMenu()
        folderMenu.addItem(.info("位置：" + (Settings.recordFolder.path as NSString).abbreviatingWithTildeInPath))
        folderMenu.addItem(ActionMenuItem("在访达中打开") {
            let folder = Settings.recordFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        })
        if let last = lastRecording {
            folderMenu.addItem(ActionMenuItem("最近一次录屏：在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([last])
            })
        }
        folderMenu.addItem(ActionMenuItem("更改位置…") { Self.chooseFolder() })
        if Settings.recordFolder != Settings.defaultRecordFolder {
            folderMenu.addItem(ActionMenuItem("恢复默认（影片/MacKit）") { Settings.recordFolder = Settings.defaultRecordFolder })
        }
        let folderItem = NSMenuItem(title: "录屏保存位置", action: nil, keyEquivalent: "")
        folderItem.submenu = folderMenu
        items.append(folderItem)

        let keyMenu = NSMenu()
        for (index, preset) in RecordHotKeyPresets.all.enumerated() {
            let item = ActionMenuItem("\(preset.display)　\(preset.note)") { [weak self] in
                Settings.recordHotKeyIndex = index
                self?.registerHotKey()
            }
            item.state = index == Settings.recordHotKeyIndex ? .on : .off
            keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "录屏快捷键：\(combo.display)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        items.append(keyItem)
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
