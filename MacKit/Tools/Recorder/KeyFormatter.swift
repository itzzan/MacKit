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
