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
