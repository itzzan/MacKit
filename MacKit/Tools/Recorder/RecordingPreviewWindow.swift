import AppKit
import AVKit

/// 录完的预览窗口：播放、剪掉开头结尾（系统自带的修剪条，和 QuickTime 一样）、保存、存成 GIF、在访达中显示、删掉
@MainActor
final class RecordingPreviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let playerView = AVPlayerView()
    private(set) var url: URL
    /// 剪好的范围（还没保存）。nil = 没剪
    private(set) var trimRange: CMTimeRange?
    var onGIF: ((URL, CMTimeRange?) -> Void)?
    var onClose: (() -> Void)?
    private let status = NSTextField(labelWithString: "")
    private(set) var buttons: [String: NSButton] = [:]

    init(url: URL) {
        self.url = url
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
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.stringValue = "拖进度条看一看；要剪就点「剪掉开头结尾」"
        let bar = NSStackView(views: views + [status])
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
    }

    /// present = false 只给自检用
    func show(present: Bool = true) {
        guard present else { return }
        Task { @MainActor in
            // 按视频比例调窗口大小，最大 960×640
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
                let scale = min(960 / size.width, 640 / size.height, 1)
                window.setContentSize(CGSize(width: max(size.width * scale, 520), height: size.height * scale + 52))
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

    /// 保存剪好的：原来的视频先移到废纸篓（想要还能找回来），剪好的用原来的文件名
    @objc func save() {
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

    @objc private func gif() { onGIF?(url, trimRange) }

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
