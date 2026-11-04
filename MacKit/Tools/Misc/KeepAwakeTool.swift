import AppKit
import IOKit.pwr_mgt

/// 防休眠积木：30 分钟 / 1 小时 / 2 小时 / 一直开着；录屏时自动开。
/// 用系统的电源"断言"（和自带的 caffeinate 命令同一个办法）挡住"闲置后屏幕变黑、电脑睡眠"，不要任何权限。
/// MacKit 退出时系统自动收回，不会留下开关
@MainActor
final class KeepAwakeTool: ToolModule {
    /// 菜单栏图标要不要换成咖啡杯（AppDelegate 里接上）
    var onChange: ((Bool) -> Void)?
    /// 手动开到几点；distantFuture = 一直开着；nil = 没开
    private(set) var until: Date?
    /// 录屏中（RecorderTool 告诉我们）
    private(set) var recording = false
    /// 自检用：只走逻辑，不真的向系统申请
    var dryRun = false
    private(set) var assertionID: IOPMAssertionID?
    private var expiry: Timer?

    static let choices: [(title: String, minutes: Int?)] = [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("一直开着", nil)]

    var manualOn: Bool { until != nil }
    var isOn: Bool { manualOn || recording }
    /// 正在挡着系统休眠（dryRun 时看 holding）
    private(set) var holding = false

    func activate() {}

    func turnOn(minutes: Int?) {
        turnOn(until: minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } ?? .distantFuture)
    }

    func turnOn(until date: Date) {
        until = date
        expiry?.invalidate()
        expiry = nil
        if date != .distantFuture {
            let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.notice("keep awake: time is up")
                    self?.turnOff()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            expiry = t
        }
        Log.app.notice("keep awake on until \(date == .distantFuture ? "forever" : date.description, privacy: .public)")
        apply()
    }

    func turnOff() {
        until = nil
        expiry?.invalidate()
        expiry = nil
        apply()
    }

    /// 录屏开始 / 结束（连同等定时开始、倒数、暂停）
    func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        apply()
    }

    private func apply() {
        let want = isOn
        if want && !holding {
            if !dryRun {
                var id = IOPMAssertionID(0)
                let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "MacKit 防休眠" as CFString, &id)
                if ok == kIOReturnSuccess { assertionID = id } else { Log.app.error("keep awake: assertion failed \(ok)") }
            }
            holding = true
        } else if !want && holding {
            if let id = assertionID { IOPMAssertionRelease(id) }
            assertionID = nil
            holding = false
        }
        onChange?(manualOn)
    }

    /// 菜单里那一行写什么
    var statusTitle: String {
        if let until {
            if until == .distantFuture { return "防休眠中（一直开着）" }
            return "防休眠中，\(SystemText.remaining(until.timeIntervalSinceNow))"
        }
        return recording ? "录屏中，自动防休眠" : "防休眠：关"
    }

    func menuItems() -> [NSMenuItem] {
        let sub = NSMenu()
        for choice in Self.choices {
            sub.addItem(ActionMenuItem(choice.title) { [weak self] in self?.turnOn(minutes: choice.minutes) })
        }
        if manualOn {
            sub.addItem(.separator())
            sub.addItem(ActionMenuItem("关掉") { [weak self] in self?.turnOff() })
        }
        sub.addItem(.separator())
        sub.addItem(.info("开着时屏幕不会变黑，电脑不会睡"))
        sub.addItem(.info("录屏时会自动开，录完恢复"))
        sub.addItem(.info("合上盖子还是会睡（除非接着电源和外接显示器）"))
        let item = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        item.submenu = sub
        item.state = isOn ? .on : .off
        return [item]
    }
}
