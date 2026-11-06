import Foundation

/// 调色板（台阶 24，纯逻辑，有单元测试）：一套起了名字的颜色，颜色存成 0xRRGGBB（和"最近的颜色"一样）
struct ColorPalette: Codable, Equatable, Identifiable {
    struct Color: Codable, Equatable {
        var value: Int
        var name: String?
    }

    let id: UUID
    var name: String
    var colors: [Color]

    init(id: UUID = UUID(), name: String, colors: [Color] = []) {
        self.id = id
        self.name = name
        self.colors = colors
    }

    /// 加一个颜色：已经有了就不再加（返回 false）
    @discardableResult
    mutating func add(_ value: Int, name: String? = nil) -> Bool {
        guard !colors.contains(where: { $0.value == value }) else { return false }
        colors.append(Color(value: value, name: name))
        return true
    }
}

enum PaletteText {
    /// 导出成哪种（复制到剪贴板）
    enum Format: Int, CaseIterable {
        case plain, css, json
        var title: String { ["纯文字", "CSS 变量", "JSON"][rawValue] }
        /// 导出菜单里的一项
        var menuTitle: String { ["复制成纯文字", "复制成 CSS 变量", "复制成 JSON"][rawValue] }
    }

    static func export(_ p: ColorPalette, as format: Format) -> String {
        switch format {
        case .plain: return plain(p)
        case .css: return css(p)
        case .json: return json(p)
        }
    }

    /// 第一行调色板的名字，下面一行一个颜色："主色 #FF3B30"；没起名字的只写 HEX
    static func plain(_ p: ColorPalette) -> String {
        ([p.name] + p.colors.map { c in
            let hex = hexText(c.value)
            return (c.name.map { $0 + " " } ?? "") + hex
        }).joined(separator: "\n")
    }

    /// CSS 变量：变量名用颜色的名字（空格换成"-"），没起名字的叫 --color-1、--color-2；重名的后面加 -2
    static func css(_ p: ColorPalette) -> String {
        var used: Set<String> = []
        var lines = ["/* \(p.name.replacingOccurrences(of: "*/", with: "* /")) */", ":root {"]
        for (i, c) in p.colors.enumerated() {
            var name = cssName(c.name) ?? "color-\(i + 1)"
            if used.contains(name) {
                var n = 2
                while used.contains("\(name)-\(n)") { n += 1 }
                name = "\(name)-\(n)"
            }
            used.insert(name)
            lines.append("  --\(name): \(hexText(c.value));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// 颜色名字变成 CSS 变量名能用的样子：空白换成"-"，标点换成"-"，中文照留；空的返回 nil
    static func cssName(_ name: String?) -> String? {
        guard let name else { return nil }
        var out = ""
        for c in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { out.append(c) }
            else if out.last != "-" { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out.isEmpty ? nil : out
    }

    /// JSON：名字、每个颜色的名字（没有就不写）、HEX、RGB
    static func json(_ p: ColorPalette) -> String {
        let colors = p.colors.map { c -> String in
            let (r, g, b) = unpack(c.value)
            var fields: [String] = []
            if let name = c.name { fields.append("\"name\": \(quoted(name))") }
            fields.append("\"hex\": \"\(hexText(c.value))\"")
            fields.append("\"rgb\": [\(r), \(g), \(b)]")
            return "    { " + fields.joined(separator: ", ") + " }"
        }
        return "{\n  \"name\": \(quoted(p.name)),\n  \"colors\": [\n" + colors.joined(separator: ",\n")
            + (colors.isEmpty ? "" : "\n") + "  ]\n}"
    }

    /// 打的 HEX 读成颜色："#FF3B30"、"ff3b30"、"#f00"（三位的每位重复一次）；读不出来是 nil
    static func parseHex(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = Int(s, radix: 16) else { return nil }
        return v
    }

    /// 新建调色板的名字：重复了就加" 2"" 3"
    static func uniqueName(_ base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "我的颜色" : trimmed
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    static func hexText(_ v: Int) -> String {
        let (r, g, b) = unpack(v)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func unpack(_ v: Int) -> (Int, Int, Int) { ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) }

    private static func quoted(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }
}
