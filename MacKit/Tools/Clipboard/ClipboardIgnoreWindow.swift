import AppKit
import UniformTypeIdentifiers

/// "不记录这些软件"的名单（台阶 14）：名单里的软件复制的东西不进剪贴板历史
@MainActor
enum ClipboardIgnoreList {
    static var ids: [String] { Settings.clipboardIgnoredApps }

    static func contains(_ id: String) -> Bool { ids.contains(id) }

    static func add(_ id: String) {
        guard !id.isEmpty, !contains(id) else { return }
        Settings.clipboardIgnoredApps = ids + [id]
        Log.app.notice("clipboard: ignore \(id, privacy: .public)")
    }

    static func remove(_ id: String) {
        Settings.clipboardIgnoredApps = ids.filter { $0 != id }
    }

    /// 软件的名字（没装就显示编号）
    static func name(of id: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(of id: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// 菜单里"不记当前软件"用的：最前面那个软件（不是 MacKit 自己）
    static var frontApp: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != nil else { return nil }
        return app
    }
}

/// 名单小窗口：列出名单，能删、能从"应用程序"里挑几个加进来
@MainActor
final class ClipboardIgnoreWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window: EditableWindow
    let table = NSTableView()
    private(set) var ids: [String] = []
    var onClose: (() -> Void)?

    override init() {
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 360),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "不记录这些软件复制的内容"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        reload()
    }

    private func build() {
        let hint = NSTextField(wrappingLabelWithString: "名单里的软件复制的东西不进剪贴板历史；之前记下的不会删。密码管理器本来就不记。")
        hint.font = Theme.small()
        hint.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = 340
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let add = NSButton(title: "添加软件…", target: self, action: #selector(addApps))
        let remove = NSButton(title: "删除", target: self, action: #selector(removeSelected))
        let done = NSButton(title: "完成", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [add, remove, NSView(), done])
        buttons.distribution = .fill
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let stack = NSStackView(views: [hint, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        hint.preferredMaxLayoutWidth = 360
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        ids = ClipboardIgnoreList.ids
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = ids[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: ClipboardIgnoreList.icon(of: id))
        let name = NSTextField(labelWithString: ClipboardIgnoreList.name(of: id))
        name.font = Theme.body(.regular)
        let row = NSStackView(views: [icon, name])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = name
        return cell
    }

    /// 从"应用程序"里挑：用不卡人的方式打开选择窗口
    @objc private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "不记录它"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { ClipboardIgnoreList.add(id) } }
                self?.reload()
            }
        }
    }

    @objc func removeSelected() {
        for i in table.selectedRowIndexes.sorted(by: >) where ids.indices.contains(i) { ClipboardIgnoreList.remove(ids[i]) }
        reload()
    }

    @objc private func finish() { window.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        if NSApp.modalWindow == nil { NSApp.hide(nil) }
    }
}
