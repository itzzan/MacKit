import AppKit
import Carbon.HIToolbox

/// MacKit 的每一个快捷键（台阶 17：设置窗口里随便设）
enum HotKeyAction: String, CaseIterable {
    case screenshot, pin, pinToggle, clipboard, record, ocr, measure, screenPen

    var title: String {
        switch self {
        case .screenshot: "截图"
        case .pin: "贴图"
        case .pinToggle: "显示 / 隐藏全部贴图"
        case .clipboard: "剪贴板历史"
        case .record: "录屏"
        case .ocr: "识别文字"
        case .measure: "测量"
        case .screenPen: "屏幕画笔"
        }
    }

    var storeKey: String { "hotkey.\(rawValue)" }

    /// "一键套用"那两套里管的这几个（屏幕画笔两套都是 ⌃⇧D）
    static let schemeActions: [HotKeyAction] = [.screenshot, .pin, .pinToggle, .clipboard, .record, .ocr, .measure]

    /// 没单独改过时用的：按以前存的"第几个预设"算（你这台就是一直用的 ⌘1–⌘6）
    @MainActor
    var presetCombo: HotKeyCombo {
        switch self {
        case .screenshot: HotKeyPresets.screenshot[Settings.screenshotHotKeyIndex]
        case .pin: PinHotKeyPresets.all[Settings.pinHotKeyIndex].pin
        case .pinToggle: PinHotKeyPresets.all[Settings.pinHotKeyIndex].toggle
        case .clipboard: ClipboardHotKeyPresets.all[Settings.clipboardHotKeyIndex]
        case .record: RecordHotKeyPresets.all[Settings.recordHotKeyIndex]
        case .ocr: RecognizeHotKeyPresets.ocr[Settings.ocrHotKeyIndex]
        case .measure: RecognizeHotKeyPresets.measure[Settings.measureHotKeyIndex]
        case .screenPen: ScreenPenHotKey.standard
        }
    }

    /// 某一套里它是什么（"一键套用"、欢迎窗口用）
    func combo(in scheme: HotKeyScheme) -> HotKeyCombo {
        let last = scheme == .control
        switch self {
        case .screenshot: return last ? HotKeyPresets.screenshot.last! : HotKeyPresets.screenshot[0]
        case .pin: return (last ? PinHotKeyPresets.all.last! : PinHotKeyPresets.all[0]).pin
        case .pinToggle: return (last ? PinHotKeyPresets.all.last! : PinHotKeyPresets.all[0]).toggle
        case .clipboard: return last ? ClipboardHotKeyPresets.all.last! : ClipboardHotKeyPresets.all[0]
        case .record: return last ? RecordHotKeyPresets.all.last! : RecordHotKeyPresets.all[0]
        case .ocr: return last ? RecognizeHotKeyPresets.ocr.last! : RecognizeHotKeyPresets.ocr[0]
        case .measure: return last ? RecognizeHotKeyPresets.measure.last! : RecognizeHotKeyPresets.measure[0]
        case .screenPen: return ScreenPenHotKey.standard
        }
    }

    /// 所有预设（自己按出来的组合和某个预设一样时，借用它的说明和"会和谁抢"）
    static var allPresets: [HotKeyCombo] {
        var list: [HotKeyCombo] = HotKeyPresets.screenshot
        for p in PinHotKeyPresets.all { list.append(p.pin); list.append(p.toggle) }
        list += ClipboardHotKeyPresets.all
        list += RecordHotKeyPresets.all
        list += RecognizeHotKeyPresets.ocr
        list += RecognizeHotKeyPresets.measure
        list.append(ScreenPenHotKey.standard)
        return list
    }
}

extension HotKeyCombo {
    /// 从"哪个键 + 哪几个修饰键"造一个（设置窗口里按出来的）
    init(keyCode: UInt16, modifiers: KeyModifiers, note: String = "") {
        var carbon = 0
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { carbon |= cmdKey; flags.insert(.command) }
        if modifiers.contains(.shift) { carbon |= shiftKey; flags.insert(.shift) }
        if modifiers.contains(.option) { carbon |= optionKey; flags.insert(.option) }
        if modifiers.contains(.control) { carbon |= controlKey; flags.insert(.control) }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: UInt32(carbon),
                  display: HotKeyRules.display(keyCode: keyCode, modifiers: modifiers),
                  menuKey: Self.menuKey(for: keyCode), menuModifiers: flags, note: note)
    }

    var keyModifiers: KeyModifiers {
        var m: KeyModifiers = []
        if carbonModifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        return m
    }

    /// 菜单项右边显示用的那个字：字母小写、F 键用系统的特殊字符
    static func menuKey(for keyCode: UInt16) -> String {
        let fKeys: [UInt16: Int] = [122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey,
                                    96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey,
                                    101: NSF9FunctionKey, 109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey]
        if let f = fKeys[keyCode], let scalar = UnicodeScalar(UInt16(f)) { return String(Character(scalar)) }
        if keyCode == 49 { return " " }
        return (KeyFormatter.printableKeys[keyCode] ?? "").lowercased()
    }
}

/// 快捷键存哪、怎么换算（台阶 17）。
/// 存法：hotkey.<功能> = {code, mods}；清掉了 = {none: true}；没存过 = 按以前的"第几个预设"
@MainActor
extension Settings {
    private static var defaults: UserDefaults { .standard }

    /// 现在用的快捷键；nil = 你把它清掉了（这个功能不要快捷键）
    static func hotKey(_ action: HotKeyAction) -> HotKeyCombo? {
        guard let saved = defaults.dictionary(forKey: action.storeKey) else { return action.presetCombo }
        if saved["none"] as? Bool == true { return nil }
        guard let code = saved["code"] as? Int, let mods = saved["mods"] as? Int else { return action.presetCombo }
        let combo = HotKeyCombo(keyCode: UInt16(code), modifiers: KeyModifiers(rawValue: mods))
        return HotKeyAction.allPresets.first { $0 == combo } ?? combo           // 和某个预设一样：带上它的说明
    }

    static func setHotKey(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        if let combo {
            defaults.set(["code": Int(combo.keyCode), "mods": combo.keyModifiers.rawValue], forKey: action.storeKey)
        } else {
            defaults.set(["none": true], forKey: action.storeKey)
        }
    }

    /// 恢复默认 = 回到以前那套里的
    static func resetHotKey(_ action: HotKeyAction) { defaults.removeObject(forKey: action.storeKey) }

    static func isCustomHotKey(_ action: HotKeyAction) -> Bool { defaults.object(forKey: action.storeKey) != nil }

    /// 除了 action 以外，别的功能现在占着的（判断撞没撞用）
    static func otherHotKeys(than action: HotKeyAction) -> [(name: String, keyCode: UInt16, modifiers: KeyModifiers)] {
        HotKeyAction.allCases.filter { $0 != action }.compactMap { a in
            hotKey(a).map { (a.title, UInt16($0.keyCode), $0.keyModifiers) }
        }
    }
}
