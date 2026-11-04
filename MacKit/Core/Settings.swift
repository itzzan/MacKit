import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键组合
struct HotKeyCombo: Equatable {
    let keyCode: UInt32               // Carbon 虚拟键码
    let carbonModifiers: UInt32       // Carbon 修饰键（cmdKey 等）
    let display: String               // 菜单里显示的样子，例如 ⌘1
    let menuKey: String               // 菜单项右侧显示用
    let menuModifiers: NSEvent.ModifierFlags
    let note: String
    /// 已知会抢同一个快捷键的软件（系统不会报冲突，两个都会响应）
    var rival: (bundleID: String, name: String)? = nil

    static func == (a: HotKeyCombo, b: HotKeyCombo) -> Bool {
        a.keyCode == b.keyCode && a.carbonModifiers == b.carbonModifiers
    }

    /// 抢快捷键的软件现在是否开着
    var runningRival: String? {
        guard let rival else { return nil }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == rival.bundleID }
        return running ? rival.name : nil
    }
}

enum HotKeyPresets {
    private static let f1 = String(Character(UnicodeScalar(UInt16(NSF1FunctionKey))!))

    /// 截图快捷键可选项。第一个是默认值（和你 Snipaste 里的设置一样）
    static let screenshot: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey),
                    display: "⌘1", menuKey: "1", menuModifiers: [.command],
                    note: "和你的 Snipaste 一样", rival: ("com.Snipaste", "Snipaste")),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘1", menuKey: "1", menuModifiers: [.command, .shift],
                    note: "和 Snipaste 同时开着时用这个"),
        HotKeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0,
                    display: "F1", menuKey: f1, menuModifiers: [],
                    note: "Snipaste 出厂设置，MacBook 上要按 fn+F1"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥A", menuKey: "a", menuModifiers: [.control, .option],
                    note: "QQ 截图习惯", rival: ("com.tencent.qq", "QQ")),
    ]
}

/// 紧急退出：MacKit 卡住时也能用（全局快捷键在卡住时照样收得到）。
/// MacKit 不在 Dock 里，系统的"强制退出"窗口找不到它，所以要有这个
enum EmergencyHotKey {
    static let quit = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
                                  display: "⌃⌥⌘Q", menuKey: "q", menuModifiers: [.control, .option, .command],
                                  note: "MacKit 卡住时紧急退出")
}

/// 贴图的一对快捷键：贴图 + 隐藏/显示全部
struct PinHotKeys {
    let pin: HotKeyCombo
    let toggle: HotKeyCombo
}

enum PinHotKeyPresets {
    private static let f3 = String(Character(UnicodeScalar(UInt16(NSF3FunctionKey))!))

    /// 第一个是默认值（2026-10-28 用户选的 ⌘2）
    static let all: [PinHotKeys] = [
        PinHotKeys(
            pin: HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey),
                             display: "⌘2", menuKey: "2", menuModifiers: [.command],
                             note: "紧挨着截图的 ⌘1"),
            toggle: HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey),
                                display: "⇧⌘2", menuKey: "2", menuModifiers: [.command, .shift],
                                note: "")),
        PinHotKeys(
            pin: HotKeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0,
                             display: "F3", menuKey: f3, menuModifiers: [],
                             note: "Snipaste 出厂设置，MacBook 上要按 fn+F3", rival: ("com.Snipaste", "Snipaste")),
            toggle: HotKeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: UInt32(shiftKey),
                                display: "⇧F3", menuKey: f3, menuModifiers: [.shift],
                                note: "", rival: ("com.Snipaste", "Snipaste"))),
    ]
}

/// 剪贴板历史的呼出快捷键。第一个是默认值（2026-11-04 用户选的 ⌘3）
enum ClipboardHotKeyPresets {
    static let all: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey),
                    display: "⌘3", menuKey: "3", menuModifiers: [.command], note: "接着截图 ⌘1、贴图 ⌘2"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘V", menuKey: "v", menuModifiers: [.command, .shift], note: "有些软件里它是「粘贴为纯文本」"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘C", menuKey: "c", menuModifiers: [.command, .shift], note: "Maccy 的默认"),
    ]
}

/// 录屏快捷键。第一个是默认值（2026-11-04 用户选的 ⌘4）
enum RecordHotKeyPresets {
    static let all: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey),
                    display: "⌘4", menuKey: "4", menuModifiers: [.command], note: "接着 ⌘1 ⌘2 ⌘3"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥R", menuKey: "r", menuModifiers: [.control, .option], note: "QQ 录屏习惯",
                    rival: ("com.tencent.qq", "QQ")),
    ]
}

/// 用户设置，存在 UserDefaults（defaults read local.mackit.MacKit 可查看）
@MainActor
enum Settings {
    private static let store = UserDefaults.standard

    static var screenshotHotKeyIndex: Int {
        get {
            let index = store.integer(forKey: "screenshot.hotkeyIndex")
            return HotKeyPresets.screenshot.indices.contains(index) ? index : 0
        }
        set { store.set(newValue, forKey: "screenshot.hotkeyIndex") }
    }

    static var screenshotHotKey: HotKeyCombo { HotKeyPresets.screenshot[screenshotHotKeyIndex] }

    static let defaultSaveFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/MacKit", isDirectory: true)

    static var saveFolder: URL {
        get {
            if let path = store.string(forKey: "screenshot.saveFolder") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultSaveFolder
        }
        set { store.set(newValue.path, forKey: "screenshot.saveFolder") }
    }

    static var saveToFile: Bool {
        get { store.object(forKey: "screenshot.saveToFile") as? Bool ?? true }
        set { store.set(newValue, forKey: "screenshot.saveToFile") }
    }

    static var pinHotKeyIndex: Int {
        get {
            let index = store.integer(forKey: "pin.hotkeyIndex")
            return PinHotKeyPresets.all.indices.contains(index) ? index : 0
        }
        set { store.set(newValue, forKey: "pin.hotkeyIndex") }
    }

    static var pinHotKeys: PinHotKeys { PinHotKeyPresets.all[pinHotKeyIndex] }

    /// 快速模式：框选松手直接复制，不出标注工具栏
    static var screenshotQuickMode: Bool {
        get { store.bool(forKey: "screenshot.quickMode") }
        set { store.set(newValue, forKey: "screenshot.quickMode") }
    }

    /// 标注上次用的颜色、粗细
    static var annotationColorIndex: Int {
        get { store.object(forKey: "annotate.color") as? Int ?? 0 }
        set { store.set(newValue, forKey: "annotate.color") }
    }

    static var annotationSizeIndex: Int {
        get { store.object(forKey: "annotate.size") as? Int ?? 1 }
        set { store.set(newValue, forKey: "annotate.size") }
    }

    static var clipboardHotKeyIndex: Int {
        get {
            let index = store.integer(forKey: "clipboard.hotkeyIndex")
            return ClipboardHotKeyPresets.all.indices.contains(index) ? index : 0
        }
        set { store.set(newValue, forKey: "clipboard.hotkeyIndex") }
    }

    static var clipboardHotKey: HotKeyCombo { ClipboardHotKeyPresets.all[clipboardHotKeyIndex] }

    /// 暂停记录剪贴板（重启后也保持）
    static var clipboardPaused: Bool {
        get { store.bool(forKey: "clipboard.paused") }
        set { store.set(newValue, forKey: "clipboard.paused") }
    }

    static var askedAccessibility: Bool {
        get { store.bool(forKey: "permission.askedAccessibility") }
        set { store.set(newValue, forKey: "permission.askedAccessibility") }
    }

    static var recordHotKeyIndex: Int {
        get {
            let index = store.integer(forKey: "record.hotkeyIndex")
            return RecordHotKeyPresets.all.indices.contains(index) ? index : 0
        }
        set { store.set(newValue, forKey: "record.hotkeyIndex") }
    }

    static var recordHotKey: HotKeyCombo { RecordHotKeyPresets.all[recordHotKeyIndex] }

    static var recordSystemAudio: Bool {
        get { store.object(forKey: "record.systemAudio") as? Bool ?? true }
        set { store.set(newValue, forKey: "record.systemAudio") }
    }

    static var recordMicrophone: Bool {
        get { store.bool(forKey: "record.microphone") }
        set { store.set(newValue, forKey: "record.microphone") }
    }

    static var recordQuality: RecordQuality {
        get { RecordQuality(rawValue: store.integer(forKey: "record.quality")) ?? .original60 }
        set { store.set(newValue.rawValue, forKey: "record.quality") }
    }

    /// 控制条上的 🖱 ⌨ 📷 三个开关：记住上次的选择
    static var recordShowClicks: Bool {
        get { store.bool(forKey: "record.showClicks") }
        set { store.set(newValue, forKey: "record.showClicks") }
    }

    static var recordShowKeys: Bool {
        get { store.bool(forKey: "record.showKeys") }
        set { store.set(newValue, forKey: "record.showKeys") }
    }

    static var recordCamera: Bool {
        get { store.bool(forKey: "record.camera") }
        set { store.set(newValue, forKey: "record.camera") }
    }

    /// 摄像头画面大小（点）和形状（默认圆形）
    static var cameraSide: CGFloat {
        get { (store.object(forKey: "record.cameraSide") as? Double).map { CGFloat($0) } ?? 180 }
        set { store.set(Double(newValue), forKey: "record.cameraSide") }
    }

    static var cameraRounded: Bool {
        get { store.bool(forKey: "record.cameraRounded") }
        set { store.set(newValue, forKey: "record.cameraRounded") }
    }

    /// 录完自动打开预览窗口（默认不开：录完直接存好，提示里能点"预览剪辑"）
    static var recordOpenPreview: Bool {
        get { store.bool(forKey: "record.openPreview") }
        set { store.set(newValue, forKey: "record.openPreview") }
    }

    static let defaultRecordFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/MacKit", isDirectory: true)

    static var recordFolder: URL {
        get {
            if let path = store.string(forKey: "record.folder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return defaultRecordFolder
        }
        set { store.set(newValue.path, forKey: "record.folder") }
    }

    static var askedScreenPermission: Bool {
        get { store.bool(forKey: "permission.askedScreen") }
        set { store.set(newValue, forKey: "permission.askedScreen") }
    }
}
