import Foundation

/// 系统状态、防休眠里要显示的文字（纯计算，有单元测试 Tests/main.swift）
enum SystemText {
    /// 字节数 → "312 GB"、"18.2 GB"、"80 KB"。decimal：磁盘、网速按 1000 算（和访达一致），内存按 1024 算（和活动监视器一致）
    static func size(_ bytes: Double, decimal: Bool) -> String {
        let base: Double = decimal ? 1000 : 1024
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(bytes, 0)
        var i = 0
        while value >= base && i < units.count - 1 {
            value /= base
            i += 1
        }
        if i == 0 { return "\(Int(value)) B" }
        if value >= 100 || i == 1 { return "\(Int(value.rounded())) \(units[i])" }
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " " + units[i]
    }

    /// 网速：每秒字节数 → "1.2 MB/s"、"80 KB/s"；不到 1 KB 也写成 KB，免得一会儿 B 一会儿 KB 跳来跳去
    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1000 ? "\(Int((max(bytesPerSecond, 0) / 1000).rounded())) KB/s" : size(bytesPerSecond, decimal: true) + "/s"
    }

    static func percent(_ fraction: Double) -> String { "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%" }

    /// CPU 使用率：两次取样的计数（用户、系统、空闲、低优先级）之差。计数是 32 位的，会绕回去，所以用"绕回减法"
    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let d = (0..<4).map { Double(current[$0] &- previous[$0]) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return (d[0] + d[1] + d[3]) / total            // 用户 + 系统 + 低优先级；第 2 个是空闲
    }

    /// 网卡计数是 32 位的，过 4 GB 会从 0 重新数
    static func counterDelta(_ old: UInt32, _ new: UInt32) -> UInt64 { UInt64(new &- old) }

    /// 活动监视器的"已使用内存" = App 内存 + 联动内存 + 被压缩（单位：页）
    static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
                           pageSize: UInt64) -> UInt64 {
        (internalPages - min(purgeablePages, internalPages) + wiredPages + compressedPages) * pageSize
    }

    static func cpuLine(_ usage: Double?) -> String { "CPU　" + (usage.map(percent) ?? "…") }

    static func memoryLine(used: UInt64, total: UInt64) -> String {
        "内存　已用 \(size(Double(used), decimal: false)) / 共 \(size(Double(total), decimal: false))"
    }

    static func networkLine(down: Double?, up: Double?) -> String {
        guard let down, let up else { return "网速　…" }
        return "网速　↓ \(rate(down))　↑ \(rate(up))"
    }

    static func diskLine(available: Int64) -> String { "磁盘　剩余 \(size(Double(available), decimal: true))" }

    /// 电池：充电中 / 已充满 / 接着电源没在充 / 用电池
    static func batteryLine(percent p: Int, charging: Bool, charged: Bool, onPower: Bool) -> String {
        let state: String
        if charging { state = "充电中" }
        else if charged || (onPower && p >= 100) { state = "已充满" }
        else if onPower { state = "接着电源" }
        else { state = "用电池" }
        return "电池　\(p)%，\(state)"
    }

    /// 防休眠还剩多久："还剩 42 分钟"、"还剩 1 小时 12 分钟"、"还剩不到 1 分钟"
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "还剩不到 1 分钟" }
        if minutes < 60 { return "还剩 \(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "还剩 \(h) 小时" : "还剩 \(h) 小时 \(m) 分钟"
    }
}
