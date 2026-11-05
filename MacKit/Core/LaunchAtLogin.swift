import AppKit
import ServiceManagement

/// 开机自动启动（台阶 17）：macOS 13 起自带的"登录项"接口。
/// 状态从系统读：你在"系统设置 → 通用 → 登录项"里关掉，这边也跟着变
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isOn: Bool { status == .enabled }

    /// 系统要你点同意（第一次加的时候可能会）
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.app.notice("launch at login \(on ? "on" : "off", privacy: .public), status \(status.rawValue)")
    }

    static var statusText: String {
        switch status {
        case .enabled: "已开：开机后自动打开 MacKit"
        case .requiresApproval: "还差一步：要在系统设置的\u{201C}登录项\u{201D}里同意"
        case .notRegistered, .notFound: "没开"        // 从没加过时系统常常回"没找到"，也就是没开
        @unknown default: "不知道"
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
