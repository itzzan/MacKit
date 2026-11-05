import AppKit
import ImageIO

/// 剪贴板历史的小窗口：能拿到键盘焦点；⌥数字、⌘P、⌘⌫ 这些在交给搜索框之前先截下来
@MainActor
final class ClipboardPanelWindow: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingKeys.handle(event, firstResponder: firstResponder) || super.performKeyEquivalent(with: event)
    }
}

/// 鼠标旁边弹出的剪贴板历史：搜索框 + 列表 + 快捷键提示
@MainActor
final class ClipboardPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    /// 正开着的那个（贴图快捷键 ⌘2 要知道）
    private(set) static weak var visible: ClipboardPanel?

    var onPaste: ((ClipboardItem, Bool) -> Void)?       // (这条, 只粘贴纯文字)
    var onPin: ((ClipboardItem) -> Void)?
    /// ⌘ 点选几条后按 ⌘回车：按点的顺序连续粘贴（台阶 14）
    var onQueue: (([ClipboardItem]) -> Void)?

    /// 上面一排"全部 | 收藏"（台阶 14），Tab 切换
    enum Tab: Int { case all, favorites }
    private(set) var tab: Tab = .all
    let tabs = NSSegmentedControl(labels: ["全部", "收藏"], trackingMode: .selectOne, target: nil, action: nil)
    /// ⌘R 改名时：借用搜索框打名字
    private(set) var renamingID: UUID?
    private var savedQuery = ""
    /// ⌘ 点选的先后（表格只记得选了哪些，不记得先点哪个）
    private(set) var pickOrder: [UUID] = []
    static let rowDragType = NSPasteboard.PasteboardType("local.mackit.clipboard.row")

    let window: ClipboardPanelWindow
    let searchField = NSTextField()
    let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "还没有记录。复制点什么试试")
    private let store: ClipboardStore
    private(set) var shown: [ClipboardItem] = []
    private let thumbnails = NSCache<NSString, NSImage>()
    static let size = CGSize(width: 440, height: 480)

    init(store: ClipboardStore) {
        self.store = store
        window = ClipboardPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isFloatingPanel = true
        window.level = .popUpMenu                          // 在贴图上面
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        buildContent()
    }

    // MARK: 界面

    private func buildContent() {
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: Self.size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.barRadius
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        window.contentView = background

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.font = .systemFont(ofSize: 15)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true                 // 键盘焦点一直在搜索框里
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsMultipleSelection = true               // ⌘ 点选几条，⌘回车连续粘贴（台阶 14）
        table.registerForDraggedTypes([Self.rowDragType])  // 收藏栏里拖着排顺序
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.action = #selector(clicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(wrappingLabelWithString: "回车粘贴　⇧回车纯文字　⌥1–9 快速粘贴　⌘P 收藏　⌘R 起名　⌘⌫ 删除　⌘2 贴图\nTab 切换全部 / 收藏　⌘ 点选几条后 ⌘回车 = 按顺序连续粘贴")
        footer.font = Theme.small()
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabClicked)
        tabs.refusesFirstResponder = true
        tabs.translatesAutoresizingMaskIntoConstraints = false
        footer.preferredMaxLayoutWidth = Self.size.width - 24
        for v in [tabs, searchField, scroll, footer, emptyLabel] as [NSView] { background.addSubview(v) }
        NSLayoutConstraint.activate([
            tabs.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            tabs.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: 显示、关闭

    /// present = false 只给自检用：不显示、不抢焦点
    func show(near mouse: CGPoint, present: Bool = true) {
        reload()
        let visibleFrame = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: mouse.x, y: mouse.y - Self.size.height)     // 左上角在鼠标处
        origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - Self.size.width - 4)
        origin.y = min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - Self.size.height - 4)
        window.setFrameOrigin(origin)
        Self.visible = self
        guard present else { return }
        NSApp.activate(ignoringOtherApps: true)            // 中文输入法要 MacKit 是当前软件
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    /// returnFocus：把焦点还给之前在用的软件
    func close(returnFocus: Bool) {
        guard Self.visible === self else { return }
        Self.visible = nil
        window.orderOut(nil)
        if returnFocus, NSApp.isActive, NSApp.modalWindow == nil { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(returnFocus: false)                          // 点了别处
    }

    // MARK: 列表

    func reload() {
        guard renamingID == nil else { return }                  // 改名时搜索框里是名字，不拿来筛
        let query = searchField.stringValue
        let source = tab == .all ? store.items : store.favorites
        shown = source.filter { ClipboardText.matches(query, in: $0.searchText + " " + $0.title + " " + ($0.favoriteName ?? "")) }
        table.reloadData()
        tabs.setLabel("收藏（\(store.favorites.count)）", forSegment: 1)
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue = tab == .favorites && store.favorites.isEmpty ? "还没有收藏。选中一条按 ⌘P 收进来"
            : store.items.isEmpty ? "还没有记录。复制点什么试试" : "没有找到"
        if !shown.isEmpty { select(0) }
    }

    /// Tab / 点上面那一排：全部 ↔ 收藏
    func setTab(_ t: Tab) {
        if renamingID != nil { cancelRename() }
        tab = t
        tabs.selectedSegment = t.rawValue
        reload()
    }

    @objc private func tabClicked() { setTab(Tab(rawValue: tabs.selectedSegment) ?? .all) }

    var selectedIndex: Int { table.selectedRow }
    var selectedItem: ClipboardItem? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }

    func select(_ index: Int) {
        guard !shown.isEmpty else { return }
        let i = min(max(index, 0), shown.count - 1)
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    /// ⌘ 点选（自检也用）：加一条或去掉一条
    func toggleSelect(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        if table.selectedRowIndexes.contains(index) {
            table.deselectRow(index)
        } else {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRowIndexes.filter { shown.indices.contains($0) }
        let ids = Set(selected.map { shown[$0].id })
        pickOrder.removeAll { !ids.contains($0) }
        for i in selected where !pickOrder.contains(shown[i].id) { pickOrder.append(shown[i].id) }
    }

    /// 按点的先后排好的几条
    var pickedItems: [ClipboardItem] { pickOrder.compactMap { id in store.items.first { $0.id == id } } }

    // MARK: 收藏栏里拖着排顺序

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tab == .favorites, searchField.stringValue.isEmpty, shown.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(shown[row].id.uuidString, forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tab == .favorites else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.rowDragType), let id = UUID(uuidString: s),
              let from = shown.firstIndex(where: { $0.id == id }) else { return false }
        moveFavorite(id, to: row > from ? row - 1 : row)
        return true
    }

    func moveFavorite(_ id: UUID, to index: Int) {
        store.moveFavorite(id, to: index)
        reload()
        if let i = shown.firstIndex(where: { $0.id == id }) { select(i) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    /// 选中的那一行：主题色圆角底、白字（台阶 10）
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipboardRowView) ?? ClipboardRowView()
        cell.identifier = id
        let item = shown[row]
        cell.configure(item: item, icon: icon(for: item), shortcut: row < 9 ? "⌥\(row + 1)" : "")
        return cell
    }

    @objc private func clicked() {
        // 单击只是选中；双击才粘贴
    }

    @objc private func doubleClicked() {
        guard let item = selectedItem else { return }
        paste(item, plainText: false)
    }

    // MARK: 操作

    func paste(_ item: ClipboardItem, plainText: Bool) {
        close(returnFocus: true)
        onPaste?(item, plainText)
    }

    /// 贴图快捷键 ⌘2：把选中的这条钉成贴图
    func requestPin() {
        guard let item = selectedItem else { return }
        close(returnFocus: true)
        onPin?(item)
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        let index = selectedIndex
        store.toggleFavorite(item.id)
        reload()
        if let i = shown.firstIndex(where: { $0.id == item.id }) { select(i) } else { select(index) }
        Toast.show(store.items.first { $0.id == item.id }?.isFavorite == true ? "✓ 收藏了" : "已取消收藏")
    }

    // MARK: ⌘R 起名字

    func startRename() {
        guard let item = selectedItem else { return }
        savedQuery = searchField.stringValue
        renamingID = item.id
        searchField.stringValue = item.favoriteName ?? ""
        searchField.placeholderString = "给这条起个名字（回车确定，Esc 取消）"
        window.makeFirstResponder(searchField)
    }

    func commitRename() {
        guard let id = renamingID else { return }
        store.setFavoriteName(id, searchField.stringValue)
        endRename()
        if let i = shown.firstIndex(where: { $0.id == id }) { select(i) }
    }

    func cancelRename() { endRename() }

    private func endRename() {
        renamingID = nil
        searchField.stringValue = savedQuery
        searchField.placeholderString = "搜索剪贴板历史"
        reload()
    }

    /// ⌘回车：⌘ 点选的几条按顺序连续粘贴
    func queuePicked() {
        let items = pickedItems.isEmpty ? (selectedItem.map { [$0] } ?? []) : pickedItems
        guard !items.isEmpty else { return }
        close(returnFocus: true)
        onQueue?(items)
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        let index = selectedIndex
        store.delete(item.id)
        reload()
        select(index)
    }

    // MARK: 键盘

    func controlTextDidChange(_ obj: Notification) { if renamingID == nil { reload() } }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(selectedIndex - 1)
        case #selector(NSResponder.moveDown(_:)): select(selectedIndex + 1)
        case #selector(NSResponder.insertNewline(_:)):
            if renamingID != nil { commitRename(); return true }
            guard let item = selectedItem else { return true }
            paste(item, plainText: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            if renamingID != nil { cancelRename(); return true }
            close(returnFocus: true)
        default: return false
        }
        return true
    }

    /// 在交给搜索框之前先截下来的键：⌥1–9、⌘P、⌘⌫、⇧回车（有的输入法会吞掉）
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if mods == .option, let n = digits[event.keyCode] {
            if shown.indices.contains(n - 1) { paste(shown[n - 1], plainText: false) }
            return true
        }
        if renamingID != nil { return false }                                                // 改名时键都交给搜索框
        if mods.isEmpty && event.keyCode == 48 { setTab(tab == .all ? .favorites : .all); return true }   // Tab
        if mods == .command && event.keyCode == 35 { togglePinSelected(); return true }      // ⌘P 收藏
        if mods == .command && event.keyCode == 15 { startRename(); return true }            // ⌘R 起名
        if mods == .command && event.keyCode == 51 { deleteSelected(); return true }         // ⌘⌫
        if mods == .command && (event.keyCode == 36 || event.keyCode == 76) { queuePicked(); return true }  // ⌘回车
        if mods == [.command, .option], tab == .favorites, let item = selectedItem,
           event.keyCode == 126 || event.keyCode == 125 {                                    // ⌥⌘↑↓：收藏里挪位置
            moveFavorite(item.id, to: selectedIndex + (event.keyCode == 126 ? -1 : 1))
            return true
        }
        let composing = (searchField.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if mods == .shift && (event.keyCode == 36 || event.keyCode == 76) && !composing {   // ⇧回车（不在拼音中）
            if let item = selectedItem { paste(item, plainText: true) }
            return true
        }
        return false
    }

    // MARK: 图标

    private func icon(for item: ClipboardItem) -> NSImage {
        let key = item.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        var image: NSImage?
        switch item.kind {
        case .image:
            if let entry = item.pasteboardItems.first?.first(where: { NSBitmapImageRep.imageTypes.contains($0.type) }),
               let data = store.data(of: entry) { image = Self.thumbnail(data) }
        case .file:
            if let link = item.pasteboardItems.first?.first(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }),
               let data = store.data(of: link), let s = String(data: data, encoding: .utf8), let url = URL(string: s) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            }
        case .text, .richText:
            if let id = item.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        let result = image ?? NSImage(systemSymbolName: item.kind == .image ? "photo" : "doc.text",
                                      accessibilityDescription: nil) ?? NSImage()
        thumbnails.setObject(result, forKey: key)
        return result
    }

    /// 缩成小图再显示，大截图也不卡
    static func thumbnail(_ data: Data, maxPixel: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

/// 列表里的一行：图标、开头一行字、来源和时间、快捷键
@MainActor
final class ClipboardRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = Theme.body(.regular)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.font = Theme.small()
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.alignment = .right
        for v in [icon, title, detail, shortcut] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private(set) var titleText = ""

    func configure(item: ClipboardItem, icon image: NSImage, shortcut key: String) {
        icon.image = image
        titleText = (item.isFavorite ? "⭐ " : "") + item.displayTitle
        title.stringValue = titleText
        var parts: [String] = []
        if item.favoriteName != nil { parts.append(item.title) }            // 起了名字：下面一行带上原来的内容
        if let name = item.sourceName { parts.append(name) }
        parts.append(ClipboardText.relativeTime(item.lastCopied))
        switch item.kind {
        case .image: if let s = item.imagePixelSize { parts.append("\(Int(s.width))×\(Int(s.height))") }
        case .file: if item.fileCount > 1 { parts.append("\(item.fileCount) 个文件") }
        case .richText: parts.append("带格式")
        case .text: break
        }
        detail.stringValue = parts.joined(separator: " · ")
        shortcut.stringValue = key
    }
}


/// 剪贴板小窗口里选中那一行的底：主题色、圆角（不管系统设置里的强调色是什么，都和 MacKit 别处一样）
final class ClipboardSelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }                         // 一直按"强调"画，选中行的字是白的
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: Theme.buttonRadius, yRadius: Theme.buttonRadius).fill()
    }
}
