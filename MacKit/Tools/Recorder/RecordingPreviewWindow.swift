import AppKit
import AVKit

/// 录完的预览窗口：播放、剪掉开头结尾（系统自带的修剪条，和 QuickTime 一样）、保存、存成 GIF、在访达中显示、删掉；
/// 台阶 21 起：勾"自动推近"，点鼠标的地方自动放大，播放时就能看到，保存时另存一份"-推近"
@MainActor
final class RecordingPreviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let playerView = AVPlayerView()
    private(set) var url: URL
    /// 剪好的范围（还没保存）。nil = 没剪
    private(set) var trimRange: CMTimeRange?
    /// GIF：哪个视频、剪好的范围、推近（勾着推近时）
    var onGIF: ((URL, CMTimeRange?, AutoZoomPlan?) -> Void)?
    var onClose: (() -> Void)?
    let status = NSTextField(labelWithString: "")
    private(set) var buttons: [String: NSButton] = [:]
    /// 录的时候记下的鼠标（nil = 录的是单个窗口，或者是 2.3 以前录的）
    private(set) var track: MouseTrack?
    let zoomBox = NSButton(checkboxWithTitle: "自动推近", target: nil, action: nil)
    let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var isZoomOn = false
    /// 最近一次另存的推近版
    private(set) var lastZoomedURL: URL?
    /// 自检时 false：不弹提示条
    var showsToast = true

    init(url: URL, track: MouseTrack? = nil) {
        self.url = url
        self.track = track
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "录屏预览 — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 520, height: 360)

        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let actions: [(String, String, String, Selector)] = [
            ("trim", "scissors", "剪掉开头结尾", #selector(trim)),
            ("save", "square.and.arrow.down", "保存", #selector(save)),
            ("gif", "photo.on.rectangle", "存成 GIF", #selector(gif)),
            ("reveal", "folder", "在访达中显示", #selector(reveal)),
            ("delete", "trash", "删掉", #selector(deleteRecording)),
        ]
        var views: [NSView] = []
        for (key, symbol, title, selector) in actions {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                             target: self, action: selector)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            buttons[key] = b
            views.append(b)
        }
        zoomBox.target = self
        zoomBox.action = #selector(zoomChanged)
        zoomPopup.addItems(withTitles: AutoZoomConfig.factors.map { "\(Self.factorText($0)) 倍" })
        zoomPopup.selectItem(at: AutoZoomConfig.factors.firstIndex(of: 2) ?? 1)
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        zoomPopup.isEnabled = false
        if track == nil {
            zoomBox.isEnabled = false
            zoomBox.title = "自动推近（没有鼠标记录）"
            zoomBox.toolTip = "录的是单个窗口（窗口会被拖来拖去，位置对不上），或者是 2.3 以前录的"
        } else {
            zoomBox.toolTip = "点鼠标的地方自动放大、跟着鼠标走，停下 2 秒拉回全景；保存时另存一份，原视频不动"
        }
        status.textColor = .secondaryLabelColor
        status.font = Theme.small()
        status.stringValue = "拖进度条看一看；要剪就点「剪掉开头结尾」"
        let bar = NSStackView(views: views + [zoomBox, zoomPopup, status])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSView()
        root.addSubview(playerView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        // 下面那排按钮（台阶 21 多了推近的勾和倍数）要放得下：窗口不能比它窄
        barWidth = ceil(bar.fittingSize.width - status.fittingSize.width + 120)
        window.minSize = CGSize(width: max(520, barWidth), height: 360)
    }

    /// 下面那排按钮至少要多宽
    private(set) var barWidth: CGFloat = 520

    /// present = false 只给自检用
    func show(present: Bool = true) {
        guard present else { return }
        Task { @MainActor in
            // 按视频比例调窗口大小，最大 960×640
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
                let scale = min(960 / size.width, 640 / size.height, 1)
                window.setContentSize(CGSize(width: max(size.width * scale, 520, barWidth), height: size.height * scale + 52))
            }
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: 按钮

    @objc private func trim() {
        guard playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, result == .okButton, let item = self.playerView.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                self.setTrim(CMTimeRange(start: start, end: end))
            }
        }
    }

    /// 记下剪好的范围（自检也用）
    func setTrim(_ range: CMTimeRange?) {
        trimRange = range
        if let r = range {
            status.stringValue = "已剪成 \(RecordGeometry.durationText(r.start.seconds)) – \(RecordGeometry.durationText(r.end.seconds))，点「保存」生效"
        }
    }

    // MARK: 自动推近（台阶 21）

    static func factorText(_ f: Double) -> String { f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f) }

    var zoomFactor: Double {
        let i = zoomPopup.indexOfSelectedItem
        return AutoZoomConfig.factors.indices.contains(i) ? AutoZoomConfig.factors[i] : 2
    }

    /// 勾着推近时用的推近计划
    var zoomPlan: AutoZoomPlan? {
        guard isZoomOn, let track else { return nil }
        var config = AutoZoomConfig()
        config.factor = zoomFactor
        return AutoZoom.plan(track, config: config)
    }

    @objc private func zoomChanged() {
        Task { @MainActor in await self.setZoom(self.zoomBox.state == .on) }
    }

    /// 打开 / 关上推近：播放器换上 / 去掉"每一帧裁剪放大"，马上能看到
    func setZoom(_ on: Bool) async {
        guard track != nil, let item = playerView.player?.currentItem else { return }
        isZoomOn = on
        zoomBox.state = on ? .on : .off
        zoomPopup.isEnabled = on
        guard let plan = zoomPlan else {
            item.videoComposition = nil
            status.stringValue = "推近关了，和原视频一样"
            return
        }
        do {
            item.videoComposition = try await VideoTools.zoomComposition(for: item.asset, plan: plan)
            status.stringValue = plan.isEmpty ? "这段没点过鼠标，推近不会有变化"
                : "点鼠标的地方放大 \(Self.factorText(plan.config.factor)) 倍；点「保存」另存一份，原视频不动"
        } catch {
            status.stringValue = "推近没能打开：\(error.localizedDescription)"
        }
    }

    /// 另存推近版（剪过头尾的话一起剪）
    @discardableResult
    func saveZoomed() async -> URL? {
        guard let plan = zoomPlan else { return nil }
        let output = VideoTools.zoomedURL(for: url)
        status.stringValue = "正在另存推近版…"
        do {
            try await VideoTools.exportZoomed(url, plan: plan, range: trimRange, to: output)
            lastZoomedURL = output
            status.stringValue = "已另存 \(output.lastPathComponent)（原视频不动）"
            if showsToast {
                Toast.show("✓ 已另存推近版　点这里在访达中显示", seconds: 5) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            status.stringValue = "推近版没存成：\(error.localizedDescription)"
            return nil
        }
    }

    /// 保存剪好的：原来的视频先移到废纸篓（想要还能找回来），剪好的用原来的文件名。
    /// 勾着推近时：另存一份"-推近"，原视频不动（台阶 21 拍板）
    @objc func save() {
        if isZoomOn {
            Task { @MainActor in await self.saveZoomed() }
            return
        }
        guard let range = trimRange else {
            Toast.show("没剪过，原视频已经存好了")
            return
        }
        let original = url
        let temp = original.deletingLastPathComponent()
            .appendingPathComponent(".mackit-trim-\(UUID().uuidString).mp4")
        status.stringValue = "正在保存…"
        Task { @MainActor in
            do {
                try await VideoTools.trim(original, range: range, to: temp)
                try FileManager.default.trashItem(at: original, resultingItemURL: nil)
                try FileManager.default.moveItem(at: temp, to: original)
                if let track = self.track {                // 鼠标记录跟着剪，以后还能推近
                    let cut = track.trimmed(from: range.start.seconds, to: range.end.seconds)
                    self.track = cut
                    MouseTrackStore.save(cut, for: original)
                }
                self.trimRange = nil
                self.playerView.player?.replaceCurrentItem(with: AVPlayerItem(url: original))
                self.status.stringValue = "已保存剪好的视频（原视频在废纸篓里）"
                Toast.show("✓ 已保存剪好的视频（\(RecordGeometry.durationText(range.duration.seconds))）")
            } catch {
                try? FileManager.default.removeItem(at: temp)
                self.status.stringValue = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func gif() { onGIF?(url, trimRange, zoomPlan) }

    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// 删掉 = 移到废纸篓
    @objc private func deleteRecording() {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            window.close()
            Toast.show("已移到废纸篓")
        } catch {
            status.stringValue = "删不掉：\(error.localizedDescription)"
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        let callback = onClose
        onClose = nil
        callback?()
    }
}
