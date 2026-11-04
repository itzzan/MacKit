import CoreGraphics
import Foundation

/// 录屏画质
enum RecordQuality: Int, CaseIterable {
    case original60 = 0      // 原始清晰度、每秒 60 帧（2026-11-04 用户选的默认）
    case hd30 = 1            // 最高 1080p、每秒 30 帧

    var title: String {
        switch self {
        case .original60: "原始清晰度、每秒 60 帧"
        case .hd30: "最高 1080p、每秒 30 帧（文件小）"
        }
    }

    var fps: Int { self == .original60 ? 60 : 30 }
}

/// 录屏的坐标和尺寸换算（纯计算，有单元测试 Tests/main.swift）
enum RecordGeometry {
    /// 覆盖层里的框（点，左下原点）→ 录制用的源区域（点，左上原点，相对这块屏幕）
    static func sourceRect(forViewRect r: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 把源区域对齐到整像素，并让像素宽高都是偶数（H.264 编码要求），不超出屏幕
    static func alignedSourceRect(_ r: CGRect, scale: CGFloat, screenSize: CGSize) -> CGRect {
        let maxW = (screenSize.width * scale).rounded(.down), maxH = (screenSize.height * scale).rounded(.down)
        var x = max((r.minX * scale).rounded(), 0), y = max((r.minY * scale).rounded(), 0)
        var w = min((r.width * scale).rounded(), maxW), h = min((r.height * scale).rounded(), maxH)
        w = max(w - w.truncatingRemainder(dividingBy: 2), 2)
        h = max(h - h.truncatingRemainder(dividingBy: 2), 2)
        x = min(x, maxW - w)
        y = min(y, maxH - h)
        return CGRect(x: x / scale, y: y / scale, width: w / scale, height: h / scale)
    }

    /// 输出视频的像素尺寸：偶数；1080p 档缩到 1920×1080 的框里（竖着的就是 1080×1920）
    static func outputSize(pixelWidth: Int, pixelHeight: Int, quality: RecordQuality) -> (width: Int, height: Int) {
        var w = Double(pixelWidth), h = Double(pixelHeight)
        if quality == .hd30 {
            let long = max(w, h), short = min(w, h)
            let factor = min(1, 1920 / long, 1080 / short)
            w *= factor
            h *= factor
        }
        // 先四舍五入（1079.9999 要算成 1080，不能舍成 1078），再往下取偶数
        let even = { (v: Double) -> Int in max(Int(v.rounded()) / 2 * 2, 2) }
        return (even(w), even(h))
    }

    /// 录制小条放哪：整屏时放屏幕顶部正中；否则放在录制区域右上角的外面，上面放不下放下面，都放不下放在区域里的右上角
    static func hudOrigin(size: CGSize, target: CGRect, visible: CGRect, fullScreen: Bool, gap: CGFloat = 12) -> CGPoint {
        if fullScreen {
            return CGPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.maxY - size.height - gap)
        }
        var x = target.maxX - size.width
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        let above = target.maxY + gap
        if above + size.height <= visible.maxY - 4 { return CGPoint(x: x, y: above) }
        let below = target.minY - gap - size.height
        if below >= visible.minY + 4 { return CGPoint(x: x, y: below) }
        return CGPoint(x: x, y: min(target.maxY, visible.maxY) - size.height - gap)
    }

    /// 菜单栏上的时长："00:42"、"12:03"、"1:02:03"
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 录屏文件名：MacKit_录屏_2026-11-04_15-20-33.mp4
    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "MacKit_录屏_\(f.string(from: date)).mp4"
    }
}
