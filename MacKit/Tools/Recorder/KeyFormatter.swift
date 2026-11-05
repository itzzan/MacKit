import Foundation

/// 按下的修饰键（不依赖 AppKit，方便单元测试）
struct KeyModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)
}

/// 按键显示成牌子上的字："⇧ ⌘ 4"、"⌘ C"、"↩"（纯计算，有单元测试 Tests/main.swift）
enum KeyFormatter {
    /// 功能键：不带修饰键也显示
    static let functionKeys: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// 字母、数字、符号键按键位认，不受 ⇧ 影响（⇧4 显示成 4，不是 $）
    static let printableKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 49: "空格",
    ]

    /// shortcutsOnly：只显示带 ⌘ ⌃ ⌥ 的组合和功能键（2026-11-04 用户选的），普通打字返回 nil
    static func text(keyCode: UInt16, modifiers: KeyModifiers, characters: String?, shortcutsOnly: Bool = true) -> String? {
        let commandLike = !modifiers.intersection([.command, .control, .option]).isEmpty
        let function = functionKeys[keyCode]
        if shortcutsOnly && !commandLike && function == nil { return nil }
        guard let key = function ?? printableKeys[keyCode] ?? characters.map({ $0.uppercased() }), !key.isEmpty else {
            return nil
        }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key)
        return parts.joined(separator: " ")
    }
}

/// 快捷键能不能设（台阶 17，纯计算，有单元测试）
enum HotKeyRules {
    enum Verdict: Equatable {
        case ok
        case needsModifier                 // 只有字母数字（或只带 ⇧）：打字时会被截走
        case sameAs(String)                // 和 MacKit 自己的另一个撞了
        case reserved(String)              // 系统或各个软件都在用的
    }

    /// F1–F20 不带修饰键也行（打字用不到）
    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// 系统自己用的、各个软件里常用的：设成全局快捷键会把它们挡掉
    static let reserved: [(keyCode: UInt16, modifiers: KeyModifiers, why: String)] = [
        (20, [.shift, .command], "系统截屏（⇧⌘3）"), (21, [.shift, .command], "系统截图（⇧⌘4）"),
        (23, [.shift, .command], "系统截图工具（⇧⌘5）"), (49, [.command], "聚焦搜索（⌘空格）"),
        (49, [.control], "切换输入法（⌃空格）"), (48, [.command], "切换软件（⌘⇥）"), (50, [.command], "切换窗口（⌘`）"),
        (12, [.control, .command], "锁定屏幕（⌃⌘Q）"), (53, [.option, .command], "强制退出（⌥⌘⎋）"),
        (12, [.control, .option, .command], "MacKit 紧急退出（⌃⌥⌘Q）"),
        (12, [.command], "退出软件（⌘Q）"), (13, [.command], "关闭窗口（⌘W）"), (4, [.command], "隐藏软件（⌘H）"),
        (46, [.command], "最小化（⌘M）"), (8, [.command], "复制（⌘C）"), (9, [.command], "粘贴（⌘V）"),
        (7, [.command], "剪切（⌘X）"), (6, [.command], "撤销（⌘Z）"), (0, [.command], "全选（⌘A）"),
        (1, [.command], "保存（⌘S）"), (45, [.command], "新建（⌘N）"), (31, [.command], "打开（⌘O）"),
        (35, [.command], "打印（⌘P）"), (17, [.command], "新标签页（⌘T）"), (3, [.command], "查找（⌘F）"),
    ]

    static func check(keyCode: UInt16, modifiers: KeyModifiers,
                      others: [(name: String, keyCode: UInt16, modifiers: KeyModifiers)]) -> Verdict {
        if modifiers.intersection([.command, .control, .option]).isEmpty && !functionKeyCodes.contains(keyCode) {
            return .needsModifier
        }
        if let r = reserved.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) { return .reserved(r.why) }
        if let o = others.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) { return .sameAs(o.name) }
        return .ok
    }

    /// 快捷键的写法：⌃⌥⇧⌘ 的顺序，紧挨着写（"⇧⌘1"），菜单、设置、提示都用这一种
    static func display(keyCode: UInt16, modifiers: KeyModifiers) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (KeyFormatter.functionKeys[keyCode] ?? KeyFormatter.printableKeys[keyCode] ?? "键\(keyCode)")
    }
}

/// 版本号比较（台阶 17，纯计算，有单元测试）："v2.0.0" 比 "1.5.1" 新
enum AppVersion {
    static func parts(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
