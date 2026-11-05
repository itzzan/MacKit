import AppKit

/// 工具箱里的一块"积木"。截图、贴图、录屏、剪贴板……每个工具实现这个协议，
/// 自己管自己的菜单项和快捷键，互不影响。加新工具 = 加一块积木。
@MainActor
protocol ToolModule: AnyObject {
    /// 启动时调用一次：注册快捷键等
    func activate()
    /// 每次打开菜单栏菜单时调用，返回这块积木的常用操作（和出问题时的提醒），放在菜单第一层
    func menuItems() -> [NSMenuItem]
    /// 快捷键在别处被换了（设置窗口里改了、欢迎窗口里选了另一套）：重新注册
    /// （不常改的设置台阶 17 起都在设置窗口里，菜单里不再有"X设置"子菜单）
    func reloadHotKeys()
}

extension ToolModule {
    func reloadHotKeys() {}
}
