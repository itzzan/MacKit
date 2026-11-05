import AppKit

/// 工具箱里的一块"积木"。截图、贴图、录屏、剪贴板……每个工具实现这个协议，
/// 自己管自己的菜单项和快捷键，互不影响。加新工具 = 加一块积木。
@MainActor
protocol ToolModule: AnyObject {
    /// 启动时调用一次：注册快捷键等
    func activate()
    /// 每次打开菜单栏菜单时调用，返回这块积木的常用操作（和出问题时的提醒），放在菜单第一层
    func menuItems() -> [NSMenuItem]
    /// 不常改的设置（快捷键、保存位置……），收进这一组最后的"设置"子菜单（台阶 10）
    func settingsItems() -> [NSMenuItem]
    /// 快捷键在别处被换了（欢迎窗口里选了另一套）：重新注册
    func reloadHotKeys()
}

extension ToolModule {
    func settingsItems() -> [NSMenuItem] { [] }
    func reloadHotKeys() {}
}
