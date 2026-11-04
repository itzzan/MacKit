@preconcurrency import ScreenCaptureKit
import AppKit
import CoreMedia

/// 长截图期间的进展（交给主线程更新控制条、预览条）
struct LongShotProgress {
    let event: ScrollStitcher.Event
    let totalHeight: Int
    let screens: Double
    let thumb: CGImage?
}

/// 盯着框里的画面：每秒最多 8 张，画面变了才会送过来。每张交给拼接算法，拼的活在后台队列里做
final class LongShotCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let fps: Int32 = 8
    let queue = DispatchQueue(label: "local.mackit.longshot")
    /// 只在 queue 里碰
    private let stitcher: ScrollStitcher
    private var stopped = false
    private var stream: SCStream?
    /// 在主线程上调
    var onProgress: (@MainActor (LongShotProgress) -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    init(maxHeight: Int = 30000) {
        stitcher = ScrollStitcher(maxHeight: maxHeight)
    }

    /// 开始拍。MacKit 自己的窗口（红框、控制条、预览条、贴图）都不拍进去
    @MainActor
    func start(region: ScreenRegion) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayGone
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let source = region.sourceRect(scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int((source.width * scale).rounded())
        config.height = Int((source.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.capture.notice("long shot started \(config.width)x\(config.height)")
    }

    /// 停下来，把拼好的长图交出来（没拍到任何画面就是 nil）
    @MainActor
    func finish(_ completion: @escaping @MainActor (CGImage?) -> Void) {
        let stream = self.stream
        self.stream = nil
        Task { @MainActor in
            try? await stream?.stopCapture()
            self.queue.async {
                self.stopped = true
                let image = self.stitcher.result().flatMap(Self.makeImage)
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
            }
        }
    }

    /// 不要了
    @MainActor
    func cancel() {
        let stream = self.stream
        self.stream = nil
        queue.async { self.stopped = true }
        Task { try? await stream?.stopCapture() }
    }

    // MARK: 收画面

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, Self.isComplete(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = Self.frame(from: buffer) else { return }
        process(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("long shot stream stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError?(error) } }
    }

    /// 在 queue 里调（自检直接喂假画面也走这里）
    func process(_ frame: StitchFrame) {
        guard !stopped else { return }
        let event = stitcher.add(frame)
        let changed: Bool
        switch event {
        case .first, .appended, .full: changed = true
        case .up(let k): changed = k > 0
        default: changed = false
        }
        let progress = LongShotProgress(event: event, totalHeight: stitcher.totalHeight, screens: stitcher.screens,
                                        thumb: changed ? stitcher.thumbnail().flatMap(Self.makeImage) : nil)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onProgress?(progress) } }
    }

    /// 只要画好了的帧（画面没变时系统也会送"空闲"帧）
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// 系统给的画面（BGRA，每行末尾可能有填充）→ 紧挨着排的像素
    static func frame(from buffer: CVPixelBuffer) -> StitchFrame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * 4
        guard width > 0, height > 0, stride >= rowBytes else { return nil }
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress! + y * rowBytes, base + y * stride, rowBytes)
            }
        }
        return StitchFrame(width: width, height: height, pixels: pixels)
    }

    /// BGRA 像素 → 图片（sRGB）
    static func makeImage(_ frame: StitchFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(frame.pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
