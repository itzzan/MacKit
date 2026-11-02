import AppKit
import CoreGraphics

/// "录屏与系统录音"权限（截图、录屏都要它）
///
/// 注意：CGPreflightScreenCaptureAccess() 的结果在授权后要重启 App 才会更新，
/// 而且系统里如果留着旧签名的记录，开关怎么拨都对不上。
/// 所以这里不拿预检结果当准，而是"先真的截一次，失败了再引导"。
@MainActor
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static var guideShowing = false

    /// 能不能去试着截屏。返回 false 表示刚弹出了系统自己的授权窗口，这次先不截
    static func readyToTry() -> Bool {
        if isGranted { return true }
        if !Settings.askedScreenPermission {
            Settings.askedScreenPermission = true
            Log.capture.notice("first time: asking system for screen capture access")
            _ = CGRequestScreenCaptureAccess()
            return false
        }
        // 预检说没有，但可能是旧结果，直接试；真失败了会走 showGuide()
        Log.capture.notice("preflight says no access, trying capture anyway")
        return true
    }

    /// 引导用户去系统设置开权限。已经开着一个提示框时不会再叠一个
    static func showGuide() {
        NSApp.activate(ignoringOtherApps: true)
        guard !guideShowing else { return }
        guideShowing = true
        defer { guideShowing = false }
        Log.capture.notice("showing permission guide")

        let alert = NSAlert()
        alert.messageText = "需要“录屏与系统录音”权限"
        alert.informativeText = """
        截图要用到这个权限。

        1. 点下面的“打开系统设置”
        2. 在列表里打开 MacKit 的开关
        3. 系统问“退出并重新打开”时点它

        开关已经打开了还是不行：在列表里选中 MacKit，点下方的“−”把它删掉，然后再按一次截图快捷键，重新授权。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func menuItem() -> NSMenuItem {
        if isGranted { return .info("屏幕录制权限：已开启") }
        return ActionMenuItem("屏幕录制权限：未开启（点这里去开）") {
            if readyToTry() { showGuide() }
        }
    }
}
