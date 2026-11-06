import CoreGraphics
import Foundation

// 截图美化的纯计算（台阶 13，有单元测试 Tests/main.swift）：留白多少、图放哪、圆角多大、背景用什么颜色

/// 一个颜色（sRGB 0…1）
struct BeautifyColor: Equatable {
    var r: Double, g: Double, b: Double
    var tuple: (Double, Double, Double) { (r, g, b) }
    /// 第一次点"自选"时取色盘里的颜色
    static let standard = BeautifyColor(r: 0.20, g: 0.47, b: 0.96)
}

/// 一种美化样式
struct BeautifyStyle: Equatable {
    enum Background: Equatable {
        case preset(Int)     // 8 种渐变之一
        case auto            // 从截图里取主色配渐变
        case none            // 不要背景：四周透明，只要圆角和阴影
        case solid(BeautifyColor)   // 自选的一个纯色（台阶 20）
    }
    enum Level: Int, CaseIterable { case small, medium, large }
    enum Corner: Int, CaseIterable { case none, small, large }
    /// 整张图的比例（台阶 20）：原样 = 截图本来的比例加留白；别的四周补背景补到这个比例
    enum Ratio: Int, CaseIterable {
        case original, wide, standard, square
        var title: String { ["原样", "16:9", "4:3", "1:1"][rawValue] }
        var value: CGFloat? { [nil, 16.0 / 9.0, 4.0 / 3.0, 1.0][rawValue] }
    }

    var background: Background = .preset(0)
    var padding: Level = .medium
    var corner: Corner = .small
    var shadow = true
    var ratio: Ratio = .original
    /// 上次自选的颜色（没在用自选背景时也记着，色块上显示它）
    var custom = BeautifyColor.standard

    /// 第一次用：蓝紫渐变、中等留白、小圆角、有阴影
    static let standard = BeautifyStyle()
}

/// 一个渐变：两个颜色（sRGB 0…1）
struct BeautifyGradient: Equatable {
    let name: String
    let from: (Double, Double, Double)
    let to: (Double, Double, Double)

    static func == (a: BeautifyGradient, b: BeautifyGradient) -> Bool {
        a.name == b.name && a.from == b.from && a.to == b.to
    }
}

enum BeautifyMath {
    static let presets: [BeautifyGradient] = [
        BeautifyGradient(name: "蓝紫", from: (0.31, 0.55, 1.00), to: (0.64, 0.35, 1.00)),
        BeautifyGradient(name: "日落", from: (1.00, 0.49, 0.37), to: (1.00, 0.71, 0.48)),
        BeautifyGradient(name: "薄荷", from: (0.26, 0.91, 0.48), to: (0.22, 0.98, 0.84)),
        BeautifyGradient(name: "海洋", from: (0.13, 0.58, 0.69), to: (0.43, 0.84, 0.93)),
        BeautifyGradient(name: "桃粉", from: (1.00, 0.60, 0.62), to: (0.98, 0.82, 0.77)),
        BeautifyGradient(name: "夜空", from: (0.08, 0.12, 0.19), to: (0.14, 0.23, 0.33)),
        BeautifyGradient(name: "柠檬", from: (0.97, 0.89, 0.42), to: (0.96, 0.65, 0.14)),
        BeautifyGradient(name: "云白", from: (0.88, 0.88, 0.88), to: (0.96, 0.97, 0.98)),
    ]

    /// 四周留白（点）：按截图短边的比例，再限制在一个范围里，太小的截图不会挤、太大的不会空
    static func padding(for size: CGSize, level: BeautifyStyle.Level) -> CGFloat {
        let short = min(size.width, size.height)
        let (ratio, low, high): (CGFloat, CGFloat, CGFloat) = switch level {
        case .small: (0.06, 16, 48)
        case .medium: (0.10, 28, 90)
        case .large: (0.16, 44, 150)
        }
        return (min(max(short * ratio, low), high)).rounded()
    }

    /// 圆角（点），不超过短边的四分之一
    static func cornerRadius(for size: CGSize, corner: BeautifyStyle.Corner) -> CGFloat {
        let r: CGFloat = switch corner {
        case .none: 0
        case .small: 8
        case .large: 18
        }
        return min(r, min(size.width, size.height) / 4)
    }

    /// 整张图多大、截图放在哪（点，左下原点）。选了比例时，先加留白，再往短的那边补齐到这个比例，截图在正中间
    static func layout(imageSize: CGSize, style: BeautifyStyle) -> (canvas: CGSize, image: CGRect) {
        let p = padding(for: imageSize, level: style.padding)
        var canvas = CGSize(width: imageSize.width + p * 2, height: imageSize.height + p * 2)
        if let r = style.ratio.value, canvas.height > 0 {
            if canvas.width / canvas.height < r {
                canvas.width = (canvas.height * r).rounded()
            } else {
                canvas.height = (canvas.width / r).rounded()
            }
        }
        let origin = CGPoint(x: ((canvas.width - imageSize.width) / 2).rounded(), y: ((canvas.height - imageSize.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: imageSize))
    }

    /// 阴影：模糊半径、往下偏多少（点）
    static func shadow(for imageSize: CGSize, padding: CGFloat) -> (blur: CGFloat, offset: CGFloat) {
        let blur = min(max(padding * 0.5, 8), 36)
        return (blur, -(blur * 0.35).rounded())
    }

    /// 自动配色：从截图缩成的小图（RGBA，每像素 4 字节）里找最多的那种鲜艳颜色，
    /// 调亮、调暗各一点做成渐变。太灰（截图几乎都是黑白灰）就用默认的蓝紫
    static func autoGradient(rgba: [UInt8], width: Int, height: Int) -> BeautifyGradient {
        var buckets = [(weight: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
        var total = 0.0
        for i in 0..<(width * height) {
            let r = Double(rgba[i * 4]) / 255, g = Double(rgba[i * 4 + 1]) / 255, b = Double(rgba[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            total += 1
            guard sat > 0.25, maxC > 0.2 else { continue }           // 灰的、太暗的不算
            let h = hue(r, g, b)
            let k = min(Int(h * 12), 11)
            let w = sat
            buckets[k].weight += w
            buckets[k].r += r * w; buckets[k].g += g * w; buckets[k].b += b * w
        }
        guard let best = buckets.max(by: { $0.weight < $1.weight }), total > 0, best.weight / total > 0.02 else {
            return presets[0]
        }
        let c = (best.r / best.weight, best.g / best.weight, best.b / best.weight)
        let light = mix(c, (1, 1, 1), 0.35), dark = mix(c, (0, 0, 0), 0.15)
        return BeautifyGradient(name: "自动", from: dark, to: light)
    }

    /// 色相 0…1
    static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return 0 }
        var h: Double
        if maxC == r { h = (g - b) / d } else if maxC == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
}
