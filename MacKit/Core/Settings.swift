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

    /// 截图快捷键可选项。设置里存的是"第几个"，所以新的只能加在最后面（1.0 起新用户默认用最后的 ⌃⇧1）
    static let screenshot: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey),
                    display: "⌘1", menuKey: "1", menuModifiers: [.command],
                    note: "和 Snipaste 常用的设置一样", rival: ("com.Snipaste", "Snipaste")),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘1", menuKey: "1", menuModifiers: [.command, .shift],
                    note: "和 Snipaste 同时开着时用这个"),
        HotKeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0,
                    display: "F1", menuKey: f1, menuModifiers: [],
                    note: "Snipaste 出厂设置，MacBook 上要按 fn+F1"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥A", menuKey: "a", menuModifiers: [.control, .option],
                    note: "QQ 截图习惯", rival: ("com.tencent.qq", "QQ")),
        HotKeyScheme.combo(1, note: "很少和别的软件冲突"),
    ]
}

/// 两套快捷键方案（1.0 起）：⌃⇧1–⌃⇧6 很少跟别的软件冲突；⌘1–⌘6 和 Snipaste 常用设置一样，但会占掉浏览器切标签
enum HotKeyScheme: String, CaseIterable {
    case control
    case command

    var title: String {
        switch self {
        case .control: "⌃⇧1 到 ⌃⇧6（推荐：很少和别的软件冲突）"
        case .command: "⌘1 到 ⌘6（和 Snipaste 常用设置一样，但浏览器里 ⌘1–⌘6 切标签会被占掉）"
        }
    }

    /// 截图、贴图、剪贴板、录屏、识别、测量各自在可选项里排第几
    var indices: [Int] {
        switch self {
        case .control: [HotKeyPresets.screenshot.count - 1, PinHotKeyPresets.all.count - 1, ClipboardHotKeyPresets.all.count - 1,
                        RecordHotKeyPresets.all.count - 1, RecognizeHotKeyPresets.ocr.count - 1, RecognizeHotKeyPresets.measure.count - 1]
        case .command: [0, 0, 0, 0, 0, 0]
        }
    }

    /// 一行写清楚这套是什么
    var summary: String {
        let p = self == .control ? "⌃⇧" : "⌘"
        return "截图 \(p)1　贴图 \(p)2　剪贴板 \(p)3　录屏 \(p)4　识别文字 \(p)5　测量 \(p)6"
    }

    /// ⌃⇧ + 数字
    static func combo(_ n: Int, note: String, alsoOption: Bool = false) -> HotKeyCombo {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        var mods = controlKey | shiftKey
        var flags: NSEvent.ModifierFlags = [.control, .shift]
        if alsoOption { mods |= optionKey; flags.insert(.option) }
        return HotKeyCombo(keyCode: UInt32(codes[n - 1]), carbonModifiers: UInt32(mods),
                           display: (alsoOption ? "⌃⌥⇧" : "⌃⇧") + "\(n)", menuKey: "\(n)", menuModifiers: flags, note: note)
    }
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

    /// 第一个是老用户的默认值（⌘2）；新的加在最后面
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
        PinHotKeys(pin: HotKeyScheme.combo(2, note: "很少和别的软件冲突"),
                   toggle: HotKeyScheme.combo(2, note: "", alsoOption: true)),
    ]
}

/// 剪贴板历史的呼出快捷键。第一个是老用户的默认值（⌘3）；新的加在最后面
enum ClipboardHotKeyPresets {
    static let all: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey),
                    display: "⌘3", menuKey: "3", menuModifiers: [.command], note: "接着截图 ⌘1、贴图 ⌘2"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘V", menuKey: "v", menuModifiers: [.command, .shift], note: "有些软件里它是「粘贴为纯文本」"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey),
                    display: "⇧⌘C", menuKey: "c", menuModifiers: [.command, .shift], note: "Maccy 的默认"),
        HotKeyScheme.combo(3, note: "很少和别的软件冲突"),
    ]
}

/// 录屏快捷键。第一个是老用户的默认值（⌘4）；新的加在最后面
enum RecordHotKeyPresets {
    static let all: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey),
                    display: "⌘4", menuKey: "4", menuModifiers: [.command], note: "接着 ⌘1 ⌘2 ⌘3"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥R", menuKey: "r", menuModifiers: [.control, .option], note: "QQ 录屏习惯",
                    rival: ("com.tencent.qq", "QQ")),
        HotKeyScheme.combo(4, note: "很少和别的软件冲突"),
    ]
}

/// 识别文字、测量的快捷键。第一个是老用户的默认值（⌘5、⌘6）；新的加在最后面
enum RecognizeHotKeyPresets {
    static let ocr: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey),
                    display: "⌘5", menuKey: "5", menuModifiers: [.command], note: "接着 ⌘1 到 ⌘4"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥O", menuKey: "o", menuModifiers: [.control, .option], note: "不占 ⌘ 数字"),
        HotKeyScheme.combo(5, note: "很少和别的软件冲突"),
    ]
    static let measure: [HotKeyCombo] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(cmdKey),
                    display: "⌘6", menuKey: "6", menuModifiers: [.command], note: "接着 ⌘5"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey),
                    display: "⌃⌥M", menuKey: "m", menuModifiers: [.control, .option], note: "不占 ⌘ 数字"),
        HotKeyScheme.combo(6, note: "很少和别的软件冲突"),
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

    /// 台阶 17 起都走 Settings.hotKey(_:)：设置窗口里单独改过的优先，没改过按"第几个预设"
    static var screenshotHotKey: HotKeyCombo? { hotKey(.screenshot) }

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

    static var pinHotKey: HotKeyCombo? { hotKey(.pin) }
    static var pinToggleHotKey: HotKeyCombo? { hotKey(.pinToggle) }

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

    static var clipboardHotKey: HotKeyCombo? { hotKey(.clipboard) }

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

    static var recordHotKey: HotKeyCombo? { hotKey(.record) }

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

    static var ocrHotKeyIndex: Int {
        get { let i = store.integer(forKey: "ocr.hotkeyIndex"); return RecognizeHotKeyPresets.ocr.indices.contains(i) ? i : 0 }
        set { store.set(newValue, forKey: "ocr.hotkeyIndex") }
    }

    static var measureHotKeyIndex: Int {
        get { let i = store.integer(forKey: "measure.hotkeyIndex"); return RecognizeHotKeyPresets.measure.indices.contains(i) ? i : 0 }
        set { store.set(newValue, forKey: "measure.hotkeyIndex") }
    }

    /// 按 C 复制颜色：HEX（默认，#FF3B30）还是 RGB（255, 59, 48）
    /// 截图美化上次用的样式（台阶 13）。背景：0–7 预设渐变、8 自动配色、9 不要背景、10 自选纯色（台阶 20）
    static var beautifyStyle: BeautifyStyle {
        get {
            var s = BeautifyStyle.standard
            if let bg = store.object(forKey: "beautify.background") as? Int {
                s.background = bg == 8 ? .auto : bg == 9 ? .none : .preset(min(max(bg, 0), BeautifyMath.presets.count - 1))
            }
            if let c = store.array(forKey: "beautify.custom") as? [Double], c.count == 3 {
                s.custom = BeautifyColor(r: c[0], g: c[1], b: c[2])
            }
            if store.integer(forKey: "beautify.background") == 10 { s.background = .solid(s.custom) }
            if let r = store.object(forKey: "beautify.ratio") as? Int, let ratio = BeautifyStyle.Ratio(rawValue: r) { s.ratio = ratio }
            if let p = store.object(forKey: "beautify.padding") as? Int, let level = BeautifyStyle.Level(rawValue: p) { s.padding = level }
            if let c = store.object(forKey: "beautify.corner") as? Int, let corner = BeautifyStyle.Corner(rawValue: c) { s.corner = corner }
            if let shadow = store.object(forKey: "beautify.shadow") as? Bool { s.shadow = shadow }
            return s
        }
        set {
            let bg: Int = switch newValue.background {
            case .preset(let i): i
            case .auto: 8
            case .none: 9
            case .solid: 10
            }
            store.set(bg, forKey: "beautify.background")
            store.set([newValue.custom.r, newValue.custom.g, newValue.custom.b], forKey: "beautify.custom")
            store.set(newValue.ratio.rawValue, forKey: "beautify.ratio")
            store.set(newValue.padding.rawValue, forKey: "beautify.padding")
            store.set(newValue.corner.rawValue, forKey: "beautify.corner")
            store.set(newValue.shadow, forKey: "beautify.shadow")
        }
    }

    /// 不记录这些软件复制的内容（台阶 14，存软件的身份编号）。第一次就有钥匙串访问
    static var clipboardIgnoredApps: [String] {
        get { store.stringArray(forKey: "clipboard.ignoredApps") ?? ["com.apple.keychainaccess"] }
        set { store.set(newValue, forKey: "clipboard.ignoredApps") }
    }

    /// 连续粘贴：贴完自动按 Tab 跳到下一个格子（台阶 23，默认关）
    static var pasteQueueTab: Bool {
        get { store.bool(forKey: "clipboard.queueTab") }
        set { store.set(newValue, forKey: "clipboard.queueTab") }
    }

    /// 调色板（台阶 24）：存成 JSON（名字、颜色数字、颜色的名字）
    static var palettes: [ColorPalette] {
        get { store.data(forKey: "color.palettes").flatMap { try? JSONDecoder().decode([ColorPalette].self, from: $0) } ?? [] }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: "color.palettes") }
    }

    /// 最近打开的是哪个调色板（⌘1 按 S 存进它）
    static var currentPaletteID: UUID? {
        get { store.string(forKey: "color.palette.current").flatMap(UUID.init(uuidString:)) }
        set { store.set(newValue?.uuidString, forKey: "color.palette.current") }
    }

    /// 最近取过的颜色（台阶 15），0xRRGGBB，最新的在前，最多 20 个
    static var recentColors: [Int] {
        get { store.array(forKey: "color.recent") as? [Int] ?? [] }
        set { store.set(Array(newValue.prefix(ColorHistory.limit)), forKey: "color.recent") }
    }

    static var colorAsHex: Bool {
        get { store.object(forKey: "color.hex") as? Bool ?? true }
        set { store.set(newValue, forKey: "color.hex") }
    }

    static var askedScreenPermission: Bool {
        get { store.bool(forKey: "permission.askedScreen") }
        set { store.set(newValue, forKey: "permission.askedScreen") }
    }

    // MARK: 1.0 起：第一次打开

    /// 第一次打开的事办过了（新用户看过欢迎窗口 / 老用户的快捷键已经原样写下来）
    static var welcomeDone: Bool {
        get { store.bool(forKey: "welcome.done") }
        set { store.set(newValue, forKey: "welcome.done") }
    }

    /// 上次打开的是哪个版本（2.0 起记；nil = 2.0 以前的版本没记过）
    static var lastVersion: String? {
        get { store.string(forKey: "app.lastVersion") }
        set { store.set(newValue, forKey: "app.lastVersion") }
    }

    /// 这台电脑上以前用过 MacKit 没有：设置里有 MacKit 自己的东西，或者存过剪贴板历史
    static var hasPreviousData: Bool {
        let domain = store.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.mackit.MacKit") ?? [:]
        let own = domain.keys.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("Apple") && !$0.hasPrefix("com.apple")
            && $0 != "welcome.done" && $0 != "app.lastVersion" }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MacKit", isDirectory: true)
        return !own.isEmpty || support.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    /// 六个快捷键一起换成某一套（设置窗口里单独改过的也一起换回这一套）
    static func apply(_ scheme: HotKeyScheme) {
        for action in HotKeyAction.schemeActions { resetHotKey(action) }
        let i = scheme.indices
        screenshotHotKeyIndex = i[0]
        pinHotKeyIndex = i[1]
        clipboardHotKeyIndex = i[2]
        recordHotKeyIndex = i[3]
        ocrHotKeyIndex = i[4]
        measureHotKeyIndex = i[5]
    }

    /// 现在用的是哪一套（单独改过某一个就哪套都不是）
    static var hotKeyScheme: HotKeyScheme? {
        HotKeyScheme.allCases.first { scheme in HotKeyAction.schemeActions.allSatisfy { hotKey($0) == $0.combo(in: scheme) } }
    }

    /// 老用户升级到 1.0：把现在用着的快捷键原样写下来，以后默认值怎么变都不影响
    static func pinCurrentHotKeys() {
        screenshotHotKeyIndex = screenshotHotKeyIndex
        pinHotKeyIndex = pinHotKeyIndex
        clipboardHotKeyIndex = clipboardHotKeyIndex
        recordHotKeyIndex = recordHotKeyIndex
        ocrHotKeyIndex = ocrHotKeyIndex
        measureHotKeyIndex = measureHotKeyIndex
    }
}

/// 第一次打开 1.0 时做什么（纯判断，自检测它）
enum FirstLaunch: Equatable {
    case nothing          // 办过了
    case keepOldHotKeys   // 老用户：快捷键原样写下来，不弹欢迎窗口
    case welcome          // 新用户：先换成 ⌃⇧ 那一套，再弹欢迎窗口

    static func decide(done: Bool, hasPreviousData: Bool) -> FirstLaunch {
        if done { return .nothing }
        return hasPreviousData ? .keepOldHotKeys : .welcome
    }
}

/// 2.0 起：以前用过 MacKit 的人，第一次打开新的大版本时弹一次"装好了"的提示条（台阶 18 拍板 A）
enum WhatsNew {
    /// 新用户走欢迎窗口，不弹；上次打开的大版本比现在小才弹（没记过 = 2.0 以前的 1.x）
    static func shouldShow(firstLaunch: FirstLaunch, lastVersion: String?, current: String) -> Bool {
        guard firstLaunch != .welcome else { return false }
        let now = AppVersion.parts(current).first ?? 0
        let before = lastVersion.flatMap { AppVersion.parts($0).first } ?? 1
        return now >= 2 && now > before
    }

    static func message(for version: String) -> String {
        let major = AppVersion.parts(version).first ?? 2
        return "MacKit \(major).0 装好了：截图能美化、剪贴板能收藏、设置都在菜单最下面"
    }
}
