import CoreGraphics
import Foundation

/// 识别文字的文字处理（纯计算，有单元测试 Tests/main.swift）
enum OCRText {
    /// "去掉换行"：把被截成好几行的话接回一段。
    /// 中文和中文之间不加空格；英文单词之间加一个空格；行尾是"-"的直接接上（连字符保留：well-known、2026-11-04 不会弄坏）
    static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let last = out.last, let first = line.first else { out = line; continue }
            if last == "-" {
                out += line
            } else if needsSpace(last, first) {
                out += " " + line
            } else {
                out += line
            }
        }
        return out
    }

    /// 一行里没有中日韩文字：把全角标点改回半角（系统把中文排第一时，代码里的 () 会认成 （））。
    /// 有中日韩文字的行不动——中文句子里本来就该是全角标点
    static func normalizePunctuation(_ line: String) -> String {
        guard !line.unicodeScalars.contains(where: isCJK) else { return line }
        var out = String.UnicodeScalarView()
        for u in line.unicodeScalars {
            if (0xFF01...0xFF5E).contains(u.value), let half = Unicode.Scalar(u.value - 0xFEE0) {
                out.append(half)
            } else if u.value == 0x3000 {
                out.append(" ")
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    /// 两边都是英文（字母、数字、英文标点）才加空格；碰到中文就不加
    static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        a.isASCII && !a.isWhitespace && b.isASCII && (b.isLetter || b.isNumber)
    }

    /// 二维码里是不是网址
    static func url(in s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}

/// 颜色写成文字
enum ColorText {
    static func hex(_ r: Int, _ g: Int, _ b: Int) -> String { String(format: "#%02X%02X%02X", r, g, b) }
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String { "\(r), \(g), \(b)" }
    static func text(_ r: Int, _ g: Int, _ b: Int, hex useHex: Bool) -> String { useHex ? hex(r, g, b) : rgb(r, g, b) }
}

/// 测量：从一个点往四个方向找"边"（颜色明显变化的地方）
enum EdgeFinder {
    /// 三个通道差的和超过这个数就算"变了"（0–765）
    static let threshold = 40

    static func differs(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > threshold
    }

    /// pixel(x, y) 给出像素颜色（像素坐标，左上原点）。返回往左、右、上、下还有几个和起点同色的像素
    static func distances(fromX x: Int, y: Int, width: Int, height: Int,
                          pixel: (Int, Int) -> (Int, Int, Int)) -> (left: Int, right: Int, up: Int, down: Int) {
        let start = pixel(x, y)
        var l = x, r = x, u = y, d = y
        while l - 1 >= 0, !differs(pixel(l - 1, y), start) { l -= 1 }
        while r + 1 < width, !differs(pixel(r + 1, y), start) { r += 1 }
        while u - 1 >= 0, !differs(pixel(x, u - 1), start) { u -= 1 }
        while d + 1 < height, !differs(pixel(x, d + 1), start) { d += 1 }
        return (x - l, r - x, y - u, d - y)
    }
}

/// 放大镜放哪：默认在鼠标右下方，靠右边就翻到左边，靠下边就翻到上边（覆盖层坐标，左下原点）
enum MagnifierGeometry {
    static func origin(size: CGSize, cursor p: CGPoint, bounds: CGRect, gap: CGFloat = 20) -> CGPoint {
        var x = p.x + gap
        var y = p.y - gap - size.height
        if x + size.width > bounds.maxX { x = p.x - gap - size.width }
        if y < bounds.minY { y = p.y + gap }
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        return CGPoint(x: x, y: y)
    }
}

/// 测量结果写成文字："120 × 48"（点）和"240 × 96"（屏幕像素）
enum MeasureText {
    /// 点数：整数就不写小数，否则保留一位
    static func points(_ pixels: Int, scale: CGFloat) -> String {
        let v = Double(pixels) / Double(scale)
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func size(widthPixels w: Int, heightPixels h: Int, scale: CGFloat) -> (points: String, pixels: String) {
        ("\(points(w, scale: scale)) × \(points(h, scale: scale))", "\(w) × \(h)")
    }
}


/// 翻译往哪种语言翻（台阶 15，纯逻辑）
enum TranslateLanguages {
    /// 结果窗口小菜单里能选的（BCP-47 代码，中文名）
    static let targets: [(code: String, name: String)] = [
        ("zh-Hans", "中文"), ("en", "英文"), ("ja", "日文"), ("ko", "韩文"),
        ("fr", "法文"), ("de", "德文"), ("es", "西班牙文"), ("ru", "俄文"),
    ]

    /// 认出来的是哪种语言（系统语言识别给的代码，比如 zh-Hans、en、ja）→ 默认翻成什么：中文翻成英文，别的翻成中文
    static func defaultTarget(forDetected code: String?) -> String {
        guard let code, !code.isEmpty else { return "zh-Hans" }
        return code.hasPrefix("zh") ? "en" : "zh-Hans"
    }

    static func name(of code: String) -> String {
        targets.first { $0.code == code }?.name ?? code
    }

    /// 源语言和目标语言是同一种（不用翻）
    static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.split(separator: "-").first == b.split(separator: "-").first
    }
}

/// 最近取过的颜色（台阶 15，纯逻辑）：最新的在前，同一个颜色挪到最前，最多 20 个。存成 0xRRGGBB
enum ColorHistory {
    static let limit = 20

    static func pack(_ r: Int, _ g: Int, _ b: Int) -> Int {
        (min(max(r, 0), 255) << 16) | (min(max(g, 0), 255) << 8) | min(max(b, 0), 255)
    }

    static func unpack(_ v: Int) -> (Int, Int, Int) { ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) }

    static func adding(_ color: Int, to list: [Int]) -> [Int] {
        Array(([color] + list.filter { $0 != color }).prefix(limit))
    }
}
