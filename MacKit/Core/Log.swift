import os

/// 日志（notice 及以上会存到磁盘）。查看：/usr/bin/log show --last 10m --predicate 'subsystem == "local.mackit"'
enum Log {
    static let app = Logger(subsystem: "local.mackit", category: "app")
    static let hotkey = Logger(subsystem: "local.mackit", category: "hotkey")
    static let capture = Logger(subsystem: "local.mackit", category: "capture")
}
