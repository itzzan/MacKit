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

extension RecordGeometry {
    /// 鼠标是不是在录制框的虚线上（虚线内外 tolerance 点以内）
    static func isNearEdge(_ p: CGPoint, of r: CGRect, tolerance: CGFloat = 6) -> Bool {
        let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
        let inner = r.insetBy(dx: tolerance, dy: tolerance)
        return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
    }

    /// 录制框最小多大（点）
    static let minRegion = CGSize(width: 40, height: 30)

    /// 改大小 / 挪位置后整理一下：不小于最小尺寸、不出屏幕
    static func clampRegion(_ r: CGRect, within bounds: CGRect) -> CGRect {
        var out = r
        out.size.width = min(max(out.width, minRegion.width), bounds.width)
        out.size.height = min(max(out.height, minRegion.height), bounds.height)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }
}

extension RecordGeometry {
    /// 按键牌子放哪：录制区域下方正中、往里一点；录整屏时在屏幕下方正中
    static func keyCastOrigin(size: CGSize, target: CGRect, visible: CGRect, fullScreen: Bool) -> CGPoint {
        let area = fullScreen ? visible : target
        var x = (area.midX - size.width / 2).rounded()
        var y = area.minY + (fullScreen ? 60 : 24)
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return CGPoint(x: x, y: y)
    }

    /// 摄像头画面一开始放哪：录制区域右下角、往里 16 点；不出屏幕
    static func cameraFrame(side: CGFloat, target: CGRect, visible: CGRect) -> CGRect {
        var x = target.maxX - side - 16
        var y = target.minY + 16
        x = min(max(x, visible.minX + 4), visible.maxX - side - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - side - 4)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 摄像头画面大小：滚轮调，最小 80、最大 400 点
    static func clampCameraSide(_ side: CGFloat) -> CGFloat { min(max(side, 80), 400) }
}

/// 定时录制的计算（纯计算，有单元测试）
enum RecordSchedule {
    /// 录多久自动停（分钟），0 = 不限时
    static let autoStopChoices = [0, 1, 5, 10, 30, 60]
    /// 几分钟后开始
    static let startInChoices = [1, 5, 10, 30]

    static func autoStopTitle(_ minutes: Int) -> String { minutes == 0 ? "不限时" : "\(minutes) 分钟后停" }

    /// 指定几点几分开始：今天这个时间已经过了就算明天
    static func nextStart(hour: Int, minute: Int, now: Date, calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        c.second = 0
        let today = calendar.date(from: c) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    /// 控制条上显示的开始时间："立即开始" / "20:00 开始" / "明天 08:30 开始"
    static func startTitle(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "立即开始" }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return calendar.isDate(date, inSameDayAs: now) ? "\(hm) 开始" : "明天 \(hm) 开始"
    }

    static func shouldAutoStop(recorded seconds: TimeInterval, limitMinutes: Int) -> Bool {
        limitMinutes > 0 && seconds >= Double(limitMinutes * 60)
    }

    /// GIF 太长会很大：超过 30 秒先提醒
    static let gifWarnSeconds: Double = 30
}


/// 屏幕画笔的放大镜（台阶 22，纯计算，有单元测试）：放大镜窗口放哪、拍哪一块、滚轮怎么调
enum MagnifierMath {
    /// 放大镜直径（点，拍板：大约 260）
    static let diameter: CGFloat = 260
    static let zoomRange: ClosedRange<CGFloat> = 1.5...4
    static let defaultZoom: CGFloat = 2

    /// 放大镜窗口：以鼠标为中心；鼠标到了屏幕边上，整个放大镜还留在屏幕里（Cocoa 坐标，左下原点）
    static func lensFrame(mouse: CGPoint, screen: CGRect, diameter d: CGFloat = diameter) -> CGRect {
        let x = min(max(mouse.x - d / 2, screen.minX), screen.maxX - d)
        let y = min(max(mouse.y - d / 2, screen.minY), screen.maxY - d)
        return CGRect(x: x, y: y, width: d, height: d)
    }

    /// 要放大的那一块（这块屏幕画面里的像素，左下原点）：以鼠标为中心、边长 直径÷倍数；不出画面
    static func sourceRect(mouse: CGPoint, screen: CGRect, pixelsPerPoint s: CGFloat, zoom: CGFloat,
                           diameter d: CGFloat = diameter) -> CGRect {
        let side = d / max(zoom, 1) * s
        let w = screen.width * s, h = screen.height * s
        let x = min(max((mouse.x - screen.minX) * s - side / 2, 0), max(w - side, 0))
        let y = min(max((mouse.y - screen.minY) * s - side / 2, 0), max(h - side, 0))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 滚轮一格：往上放大、往下缩小，每格 0.25 倍，1.5–4 倍之间
    static func zoom(_ current: CGFloat, step: Int) -> CGFloat {
        min(max(current + CGFloat(step) * 0.25, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
