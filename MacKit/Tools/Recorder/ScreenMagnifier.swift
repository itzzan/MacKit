import AppKit
import CoreImage
import ScreenCaptureKit

/// 屏幕画笔的放大镜（台阶 22）：跟着鼠标的圆形放大镜，里面是实时的画面（下面在放的视频、画的东西都在）。
/// 用录屏的接口拍整块屏幕（排除放大镜自己，不然"镜中镜"；也排除画笔的小工具、录制小条这些不录的窗口），
/// 每秒 60 次把鼠标附近那一块放大贴上来。放大镜不接鼠标：点下去照样落在下面的画布上
@MainActor
final class ScreenMagnifier {
    let panel: NSPanel
    let screenFrame: CGRect
    private let lensLayer = CALayer()
    private(set) var zoom = MagnifierMath.defaultZoom
    private(set) var isOn = false
    /// 正在拍画面（自检里不拍）
    private(set) var isCapturing = false
    private var timer: Timer?
    private var stream: SCStream?
    private let sink = MagnifierSink()
    private let context = CIContext()
    private let displayID: CGDirectDisplayID?
    /// 鼠标在哪（实录检查里换成固定的点）
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// 拍画面时还要去掉哪些窗口（画笔的小工具；录屏时还有录制小条、红框）
    var excludedWindows: () -> [CGWindowID] = { [] }
    var onFail: ((String) -> Void)?

    init(screen: NSScreen?) {
        screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        displayID = screen?.displayID
        let d = MagnifierMath.diameter
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: d, height: d), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // 在画布上面，小工具下面
        panel.ignoresMouseEvents = true                 // 不挡鼠标：点下去落在画布上，照样能画
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(x: 0, y: 0, width: d, height: d))
        view.wantsLayer = true
        lensLayer.frame = view.bounds
        lensLayer.cornerRadius = d / 2
        lensLayer.masksToBounds = true
        lensLayer.borderWidth = 3
        lensLayer.borderColor = Theme.accent.cgColor                 // 一圈主题蓝：一眼看出是放大镜
        lensLayer.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        lensLayer.contentsGravity = .resize
        view.layer?.addSublayer(lensLayer)
        panel.contentView = view
    }

    /// present = false 只给自检用：不显示、不拍画面
    func show(present: Bool = true) {
        guard !isOn else { return }
        isOn = true
        follow()
        guard present else { return }
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in await self.startCapture() }
    }

    func hide() {
        guard isOn else { return }
        isOn = false
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        let s = stream
        stream = nil
        isCapturing = false
        lensLayer.contents = nil
        Task { try? await s?.stopCapture() }            // 收起就停掉拍画面，不白费电
    }

    /// 滚轮：往上一格放大 0.25 倍，往下缩小（1.5–4 倍）
    func adjustZoom(step: Int) { zoom = MagnifierMath.zoom(zoom, step: step) }

    /// 放大镜跟到鼠标那里（靠边时不出屏幕）
    func follow() {
        panel.setFrame(MagnifierMath.lensFrame(mouse: mouseLocation(), screen: screenFrame), display: false)
    }

    private func tick() {
        follow()
        guard let buffer = sink.latest else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let pixelsPerPoint = image.extent.width / max(screenFrame.width, 1)
        let source = MagnifierMath.sourceRect(mouse: mouseLocation(), screen: screenFrame, pixelsPerPoint: pixelsPerPoint, zoom: zoom)
        let side = MagnifierMath.diameter * pixelsPerPoint
        let scaled = image.cropped(to: source)
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY)
                .concatenating(CGAffineTransform(scaleX: side / source.width, y: side / source.height)))
        lensLayer.contents = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isOn, let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
            let skip = Set(excludedWindows() + [CGWindowID(panel.windowNumber)])
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { skip.contains($0.windowID) })
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await s.startCapture()
            guard isOn else { try? await s.stopCapture(); return }
            stream = s
            isCapturing = true
        } catch {
            Log.capture.error("magnifier capture failed: \(error.localizedDescription, privacy: .public)")
            onFail?(ScreenPermission.isGranted ? "放大镜没能打开：\(error.localizedDescription)" : "放大镜要\u{201C}屏幕录制\u{201D}权限")
            hide()
        }
    }
}

/// 收画面：只留最新的一帧（拍的线程上收，主线程上取）
final class MagnifierSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.mackit.magnifier")
    private let lock = NSLock()
    private var frame: CVPixelBuffer?

    var latest: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }   // 画面没变的帧没有图
        lock.lock()
        frame = buffer
        lock.unlock()
    }
}
