import Foundation

/// 剪贴板历史里的文字处理（纯计算，有单元测试 Tests/main.swift）
enum ClipboardText {
    /// 列表里显示的一行：去掉首尾空白，换行和连续空白压成一个空格，最多 maxLength 个字
    static func title(from text: String, maxLength: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.count > maxLength ? String(collapsed.prefix(maxLength)) + "…" : collapsed
    }

    /// 搜索：不分大小写、不分全角半角和重音；空查询全部匹配
    static func matches(_ query: String, in text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// "刚刚 / 3 分钟前 / 2 小时前 / 昨天 / 10-28"
    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) 小时前" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

/// 连续粘贴的队伍（台阶 14，纯逻辑，有单元测试）。
/// 还没开始贴时，新复制的排到队尾；开始贴以后不再收（拍板：不打乱队伍）
struct PasteQueue<Element> {
    private(set) var items: [Element]
    /// 下一个要贴第几条（0 起）；贴过几条 = next
    private(set) var next = 0

    init(_ items: [Element] = []) { self.items = items }

    var count: Int { items.count }
    var started: Bool { next > 0 }
    var isFinished: Bool { started && next >= items.count }
    var upcoming: Element? { items.indices.contains(next) ? items[next] : nil }

    @discardableResult
    mutating func append(_ e: Element) -> Bool {
        guard !started else { return false }
        items.append(e)
        return true
    }

    /// ⌘V：拿出下一条
    mutating func take() -> Element? {
        guard let e = upcoming else { return nil }
        next += 1
        return e
    }
}

extension ClipboardText {
    /// 连续粘贴小条上的字
    static func queueStatus(taken: Int, count: Int, upcoming: String?) -> String {
        if count == 0 { return "连续粘贴：按顺序复制几段，再到要填的地方按 ⌘V" }
        if taken >= count { return "连续粘贴完了" }
        let preview = upcoming.map { s -> String in
            let line = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return line.count > 14 ? String(line.prefix(14)) + "…" : line
        } ?? ""
        if taken == 0 { return "连续粘贴：已排 \(count) 条，到要填的地方按 ⌘V　第一条：\(preview)" }
        return "连续粘贴 \(taken + 1) / \(count)　下一条：\(preview)"
    }
}

// MARK: 改格式粘贴（台阶 23，纯计算，有单元测试）

extension ClipboardText {
    /// ⌘T 小菜单里的五种
    enum Format: Int, CaseIterable {
        case joinLines, squeezeSpaces, upper, lower, capitalize

        var title: String {
            ["去掉断行（一行行接成一段，空行处分段）", "去掉多余空格和空行", "全大写", "全小写", "每个词首字母大写"][rawValue]
        }
    }

    static func reformat(_ text: String, _ format: Format) -> String {
        switch format {
        case .joinLines: return joinLines(text)
        case .squeezeSpaces: return squeezeSpaces(text)
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .capitalize: return capitalizeWords(text)
        }
    }

    /// 去掉断行：一行行接成一段，只有空白的行算分段（留一个空行）。
    /// 接的时候：前一行最后一个字或后一行第一个字是中文、日文或全角标点，直接接上；不然中间加一个空格。
    /// 行尾是英文单词断开的"-"：直接接上、"-"留着（宁可多一个"-"，也不把 well-known 拼成 wellknown）
    static func joinLines(_ text: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        for line in cleanLines(text) {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
            } else if current.isEmpty {
                current = line
            } else {
                current += needsSpace(between: current, and: line) ? " " + line : line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 去掉多余空格：连着的空格压成一个，每行首尾的空格去掉，好几个空行压成一个（开头结尾的空行去掉）
    static func squeezeSpaces(_ text: String) -> String {
        var out: [String] = []
        for line in cleanLines(text) {
            if line.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// 每个英文词的第一个字母大写，别的字母不动（iPhone 不会变成 Iphone）；don't 的 t 不算新词
    static func capitalizeWords(_ text: String) -> String {
        var out = ""
        var atWordStart = true
        for c in text {
            if isCJK(c) {
                out.append(c)
                atWordStart = true
            } else if c.isLetter {
                out += atWordStart ? c.uppercased() : String(c)
                atWordStart = false
            } else if c.isNumber {
                out.append(c)
                atWordStart = false
            } else if c == "'" || c == "\u{2019}" {
                out.append(c)
            } else {
                out.append(c)
                atWordStart = true
            }
        }
        return out
    }

    /// 拆成行：认 \n、\r\n、\r；每行首尾的空格去掉，中间连着的空格压成一个（全角空格、不换行空格也算）
    private static func cleanLines(_ text: String) -> [String] {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
        return unified.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: isSpaceLike).joined(separator: " ")
        }
    }

    private static func isSpaceLike(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{00A0}" || c == "\u{3000}"
    }

    private static func needsSpace(between a: String, and b: String) -> Bool {
        guard let last = a.last, let first = b.first else { return false }
        if isCJK(last) || isCJK(first) { return false }
        // 英文单词在行尾被"-"断开：接上不加空格
        if last == "-", a.dropLast().last?.isLetter == true, first.isLetter { return false }
        return true
    }

    /// 中文、日文的字和全角标点（韩文词之间本来有空格，不算）
    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2FFFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x3000...0x303F).contains(v) || (0x3040...0x30FF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }
}
