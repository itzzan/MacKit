@preconcurrency import ScreenCaptureKit
import AVFoundation

/// 录哪些声音、什么画质
struct RecordOptions: Equatable {
    var systemAudio: Bool
    var microphone: Bool
    var quality: RecordQuality
    /// 录出来的视频里每次点击画个圈（macOS 15 自带）
    var showClicks = false
    /// 录制时显示按了什么键（按键牌子是 MacKit 的窗口，会被录进去）
    var showKeys = false
}

/// 算好的录制参数（自检测这个）
struct RecordPlan: Equatable {
    var sourceRect: CGRect?          // 点，左上原点，相对屏幕；nil = 整个画面
    var width: Int                   // 输出像素
    var height: Int
    var fps: Int
}

enum RecorderError: LocalizedError {
    case displayGone, windowGone

    var errorDescription: String? {
        switch self {
        case .displayGone: "找不到这块屏幕（外接屏拔掉了？）"
        case .windowGone: "找不到这个窗口（已经关掉了？）"
        }
    }
}

/// 收下画面和声音但什么都不做：录成文件由 SCRecordingOutput 负责，这里只是让录制流跑起来
final class DiscardStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

/// 用 macOS 15 的 ScreenCaptureKit 直接录成 mp4
@MainActor
final class ScreenRecorder: NSObject {
    let url: URL
    private(set) var startedAt: Date?
    var onFinished: ((Result<URL, Error>) -> Void)?

    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private let sink = DiscardStreamOutput()
    private let sinkQueue = DispatchQueue(label: "local.mackit.recorder.samples")
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    // MARK: 参数

    static func plan(for target: RecordTarget, quality: RecordQuality, scale: CGFloat, contentSize: CGSize) -> RecordPlan {
        switch target {
        case .display:
            let out = RecordGeometry.outputSize(pixelWidth: Int((contentSize.width * scale).rounded()),
                                                pixelHeight: Int((contentSize.height * scale).rounded()), quality: quality)
            return RecordPlan(sourceRect: nil, width: out.width, height: out.height, fps: quality.fps)
        case .region(_, let screenFrame, let viewRect):
            let source = RecordGeometry.alignedSourceRect(
                RecordGeometry.sourceRect(forViewRect: viewRect, screenHeight: screenFrame.height),
                scale: scale, screenSize: screenFrame.size)
            let out = RecordGeometry.outputSize(pixelWidth: Int((source.width * scale).rounded()),
                                                pixelHeight: Int((source.height * scale).rounded()), quality: quality)
            return RecordPlan(sourceRect: source, width: out.width, height: out.height, fps: quality.fps)
        case .window:
            let out = RecordGeometry.outputSize(pixelWidth: Int((contentSize.width * scale).rounded()),
                                                pixelHeight: Int((contentSize.height * scale).rounded()), quality: quality)
            return RecordPlan(sourceRect: nil, width: out.width, height: out.height, fps: quality.fps)
        }
    }

    static func configuration(plan: RecordPlan, options: RecordOptions) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = plan.width
        c.height = plan.height
        if let source = plan.sourceRect { c.sourceRect = source }
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        c.showsCursor = true
        c.pixelFormat = kCVPixelFormatType_32BGRA    // 点击画圈要求 BGRA；默认不是 BGRA，所以明确指定
        c.showMouseClicks = options.showClicks
        c.scalesToFit = true                         // 录窗口时窗口变大变小，画面按比例缩放不变形
        c.queueDepth = 8
        c.captureResolution = .best
        c.capturesAudio = options.systemAudio
        c.excludesCurrentProcessAudio = true         // 不录 MacKit 自己的声音
        c.sampleRate = 48_000
        c.channelCount = 2
        c.captureMicrophone = options.microphone
        if options.microphone {
            c.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }
        return c
    }

    // MARK: 开始、停止

    /// excluding：录制时要从画面里去掉的 MacKit 窗口（红框等）
    func start(target: RecordTarget, options: RecordOptions, excluding windowNumbers: [CGWindowID]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let excluded = content.windows.filter { windowNumbers.contains($0.windowID) }
        let filter: SCContentFilter
        switch target {
        case .display(let id, _), .region(let id, _, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.displayGone }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.windowGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let plan = Self.plan(for: target, quality: options.quality, scale: CGFloat(filter.pointPixelScale),
                             contentSize: filter.contentRect.size)
        let config = Self.configuration(plan: plan, options: options)

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264       // 微信、QQ、手机都能放
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
        if options.systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sinkQueue) }
        if options.microphone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sinkQueue) }
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        self.stream = stream
        self.recording = recording
        startedAt = Date()
        Log.capture.notice("recording started \(plan.width)x\(plan.height)@\(plan.fps) audio=\(options.systemAudio) mic=\(options.microphone)")
    }

    func stop() async {
        guard let stream else { finish(.success(url)); return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.capture.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
        // 正常情况下 recordingOutputDidFinishRecording 会来；万一没来，2 秒后按文件在不在收尾
        try? await Task.sleep(for: .seconds(2))
        finish(.success(url))
    }

    var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    fileprivate func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        stream = nil
        recording = nil
        onFinished?(result)
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Log.capture.error("recording stream stopped: \(error.localizedDescription, privacy: .public)")
            self.finish(.failure(error))
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.capture.notice("recording output started")
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            Log.capture.error("recording output failed: \(error.localizedDescription, privacy: .public)")
            self.finish(.failure(error))
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            Log.capture.notice("recording output finished")
            self.finish(.success(self.url))
        }
    }
}
