import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoToolError: LocalizedError {
    case nothingToMerge, exportUnavailable, gifFailed

    var errorDescription: String? {
        switch self {
        case .nothingToMerge: "没有录到内容"
        case .exportUnavailable: "系统不支持导出这个视频"
        case .gifFailed: "GIF 写不出来"
        }
    }
}

/// 视频处理：拼接、剪辑导出、存成 GIF。拼接和剪辑都不重新压缩（无损、很快）
enum VideoTools {
    /// 暂停时录成的几段 → 一个 mp4
    static func concatenate(_ parts: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var videoTrack: AVMutableCompositionTrack?
        var audioTracks: [AVMutableCompositionTrack] = []
        for url in parts {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            let whole = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                if videoTrack == nil {
                    videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    videoTrack?.preferredTransform = try await v.load(.preferredTransform)
                }
                try videoTrack?.insertTimeRange(whole.intersection(try await v.load(.timeRange)), of: v, at: cursor)
            }
            for (i, a) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                while audioTracks.count <= i {
                    guard let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { break }
                    audioTracks.append(t)
                }
                guard audioTracks.indices.contains(i) else { continue }
                let range = whole.intersection(try await a.load(.timeRange))
                if range.duration > .zero { try audioTracks[i].insertTimeRange(range, of: a, at: cursor + range.start) }
            }
            cursor = cursor + duration
        }
        guard cursor > .zero else { throw VideoToolError.nothingToMerge }
        try await export(composition, to: output, range: nil)
    }

    /// 剪掉开头结尾：只留 range 这一段
    static func trim(_ url: URL, range: CMTimeRange, to output: URL) async throws {
        try await export(AVURLAsset(url: url), to: output, range: range)
    }

    static func export(_ asset: AVAsset, to output: URL, range: CMTimeRange?) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoToolError.exportUnavailable
        }
        if let range { session.timeRange = range }
        try await session.export(to: output, as: .mp4)
    }

    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
    }

    /// 存成循环播放的 GIF：每秒 fps 帧，最宽 maxWidth 像素（只缩不放）。返回写了几帧
    @discardableResult
    static func makeGIF(from url: URL, range: CMTimeRange? = nil, to output: URL, maxWidth: CGFloat = 800, fps: Int = 10,
                        progress: ((Double) -> Void)? = nil) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let r = range ?? CMTimeRange(start: .zero, duration: duration)
        let count = max(Int((r.duration.seconds * Double(fps)).rounded(.down)), 1)
        let times = (0..<count).map { CMTime(seconds: r.start.seconds + Double($0) / Double(fps), preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: 100_000)
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw VideoToolError.gifFailed
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                               kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        var written = 0
        for await frame in generator.images(for: times) {
            guard let image = try? frame.image else { continue }
            CGImageDestinationAddImage(dest, image, frameProperties)
            written += 1
            progress?(Double(written) / Double(count))
        }
        guard written > 0, CGImageDestinationFinalize(dest) else { throw VideoToolError.gifFailed }
        return written
    }
}
