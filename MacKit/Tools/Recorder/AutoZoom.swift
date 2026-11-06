import CoreGraphics
import Foundation

// 录屏自动推近（台阶 21）的纯计算，有单元测试 Tests/main.swift。
// 位置都用"画面里的比例"：0…1，左上角是 (0, 0)，和视频多大、是不是 Retina 无关

/// 录的时候记下的鼠标：视频里的时间（秒，暂停那段不算）→ 鼠标在画面里哪；还有每次点击的时刻
struct MouseTrack: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var t: Double
        var x: Double
        var y: Double
    }
    var samples: [Sample] = []
    var clicks: [Double] = []
    var duration: Double = 0

    /// 屏幕上的点（Cocoa 全局坐标，左下原点）→ 画面里的比例（左上原点）。出了画面也照记（推近时会被限制在画面里）
    static func normalize(_ p: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (p.x - frame.minX) / frame.width, y: (frame.maxY - p.y) / frame.height)
    }

    /// 只留 range 这一段，时间从 0 重新算（剪掉开头结尾后保存时用）
    func trimmed(from start: Double, to end: Double) -> MouseTrack {
        MouseTrack(samples: samples.filter { $0.t >= start && $0.t <= end }.map { Sample(t: $0.t - start, x: $0.x, y: $0.y) },
                   clicks: clicks.filter { $0 >= start && $0 <= end }.map { $0 - start },
                   duration: max(min(end, duration) - start, 0))
    }
}

/// 推近的规矩（拍板：点鼠标推近，两次不到 2 秒算一段，停 2 秒拉回）
struct AutoZoomConfig: Equatable {
    var factor: Double = 2            // 放大几倍：1.5 / 2 / 2.5
    var lead: Double = 0.3            // 点之前多久开始推
    var zoomIn: Double = 0.5          // 推到位要多久
    var maxGap: Double = 2.0          // 两次点击不到这么久，算同一段
    var hold: Double = 2.0            // 最后一下之后多久开始拉回
    var zoomOut: Double = 0.8         // 拉回要多久
    var follow: Double = 0.25         // 镜头跟鼠标的"慢半拍"（秒），越大越稳

    static let factors: [Double] = [1.5, 2, 2.5]
}

/// 算好的一次推近：给一个时刻，告诉你画面里要留哪一块（比例，左上原点）
struct AutoZoomPlan: Equatable, Sendable {
    let config: AutoZoomConfig
    let segments: [ClosedRange<Double>]
    /// 平滑过的镜头中心，每 step 秒一个
    let centers: [CGPoint]
    let step: Double

    /// 0 = 全景，1 = 推到位
    func level(at t: Double) -> Double { AutoZoom.level(at: t, segments: segments, config: config) }

    func center(at t: Double) -> CGPoint {
        guard !centers.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let i = t / step
        let a = Int(max(min(i.rounded(.down), Double(centers.count - 1)), 0))
        let b = min(a + 1, centers.count - 1)
        let f = CGFloat(max(min(i - Double(a), 1), 0))
        return CGPoint(x: centers[a].x + (centers[b].x - centers[a].x) * f, y: centers[a].y + (centers[b].y - centers[a].y) * f)
    }

    /// 这一刻画面里留哪一块
    func rect(at t: Double) -> CGRect {
        let scale = 1 + (config.factor - 1) * AutoZoom.ease(level(at: t))
        return AutoZoom.cropRect(center: center(at: t), scale: scale)
    }

    /// 有没有要推近的地方（一次都没点过 = 和原视频一样）
    var isEmpty: Bool { segments.isEmpty }
}

extension AutoZoomConfig: Sendable {}

enum AutoZoom {
    /// 点击按"两次不到 maxGap 秒"分段
    static func segments(clicks: [Double], maxGap: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for c in clicks.sorted() {
            if let last = result.last, c - last.upperBound < maxGap {
                result[result.count - 1] = last.lowerBound...c
            } else {
                result.append(c...c)
            }
        }
        return result
    }

    /// 推到什么程度（0…1，没加缓动）：每一段 提前 lead 开始、zoomIn 秒推满、最后一下后 hold 秒开始拉回、zoomOut 秒拉完；几段叠在一起取最大
    static func level(at t: Double, segments: [ClosedRange<Double>], config c: AutoZoomConfig) -> Double {
        var best = 0.0
        for s in segments {
            let inStart = s.lowerBound - c.lead, inEnd = inStart + c.zoomIn
            let outStart = s.upperBound + c.hold, outEnd = outStart + c.zoomOut
            let v: Double
            if t <= inStart || t >= outEnd { v = 0 }
            else if t < inEnd { v = (t - inStart) / c.zoomIn }
            else if t <= outStart { v = 1 }
            else { v = 1 - (t - outStart) / c.zoomOut }
            best = max(best, v)
        }
        return best
    }

    /// 缓动：开头结尾都慢，中间快，推近拉回不生硬
    static func ease(_ x: Double) -> Double {
        let v = max(min(x, 1), 0)
        return v * v * (3 - 2 * v)
    }

    /// 某一刻鼠标在哪（两次记录之间按直线补）
    static func position(at t: Double, samples: [MouseTrack.Sample]) -> CGPoint {
        guard let first = samples.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard t > first.t else { return CGPoint(x: first.x, y: first.y) }
        guard let last = samples.last, t < last.t else { return CGPoint(x: samples.last!.x, y: samples.last!.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// 画面里留的那一块：放大 scale 倍时宽高都是 1/scale，中心尽量在 center，整块不出画面
    static func cropRect(center: CGPoint, scale: Double) -> CGRect {
        let s = max(scale, 1)
        let w = 1 / s, h = 1 / s
        let x = min(max(Double(center.x) - w / 2, 0), 1 - w)
        let y = min(max(Double(center.y) - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 镜头中心：跟着鼠标，但"慢半拍"地跟（一阶低通），小抖动不跟。每 step 秒算一个。
    /// 跟的是 follow 秒之后鼠标会在的地方：慢半拍和往前看半拍抵掉，点下去那一刻镜头正好到
    static func smoothedCenters(samples: [MouseTrack.Sample], duration: Double, step: Double, follow: Double) -> [CGPoint] {
        let count = max(Int((duration / step).rounded(.up)) + 1, 1)
        let alpha = follow > 0 ? 1 - exp(-step / follow) : 1
        var current = position(at: follow, samples: samples)
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let target = position(at: Double(i) * step + follow, samples: samples)
            current = CGPoint(x: current.x + (target.x - current.x) * alpha, y: current.y + (target.y - current.y) * alpha)
            result.append(current)
        }
        return result
    }

    static func plan(_ track: MouseTrack, config: AutoZoomConfig) -> AutoZoomPlan {
        let step = 1.0 / 60
        let duration = max(track.duration, track.samples.last?.t ?? 0, track.clicks.max() ?? 0)
        return AutoZoomPlan(config: config, segments: segments(clicks: track.clicks, maxGap: config.maxGap),
                            centers: smoothedCenters(samples: track.samples, duration: duration, step: step, follow: config.follow),
                            step: step)
    }
}
