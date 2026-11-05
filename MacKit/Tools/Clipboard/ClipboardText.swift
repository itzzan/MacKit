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
