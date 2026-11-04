import AppKit

/// 要录哪里
enum RecordTarget: Equatable {
    /// 整块屏幕
    case display(id: CGDirectDisplayID, screenFrame: CGRect)
    /// 屏幕上框出来的一块。viewRect 是覆盖层坐标（点，左下原点，相对这块屏幕）
    case region(id: CGDirectDisplayID, screenFrame: CGRect, viewRect: CGRect)
    /// 一个窗口（被挡住、拖走都照录）。globalFrame 是选的时候它在屏幕上的位置
    case window(id: CGWindowID, globalFrame: CGRect)

    /// 在屏幕上的位置（Cocoa 全局坐标），摆控制条、红框用
    var globalFrame: CGRect {
        switch self {
        case .display(_, let frame): frame
        case .region(_, let frame, let r): r.offsetBy(dx: frame.minX, dy: frame.minY)
        case .window(_, let frame): frame
        }
    }

    var title: String {
        switch self {
        case .display: "整块屏幕"
        case .region: "选中的区域"
        case .window: "这个窗口"
        }
    }
}
