import AppKit

/// 工具箱里的一块"积木"。截图、贴图、录屏、剪贴板……每个工具实现这个协议，
/// 自己管自己的菜单项和快捷键，互不影响。加新工具 = 加一块积木。
@MainActor
protocol ToolModule: AnyObject {
    /// 启动时调用一次：注册快捷键等
    func activate()
    /// 每次打开菜单栏菜单时调用，返回这块积木的菜单项
    func menuItems() -> [NSMenuItem]
}
