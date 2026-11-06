import AppKit

/// 调色板（台阶 24）：存在设置里，⌘1 取色时按 S 存进"最近打开的那个"
@MainActor
enum Palettes {
    static var all: [ColorPalette] { Settings.palettes }

    /// 最近打开的那个；记的那个被删了就用第一个
    static var current: ColorPalette? {
        let list = all
        return list.first { $0.id == Settings.currentPaletteID } ?? list.first
    }

    /// 新建一个（名字重复就加" 2"），并且当成最近打开的
    @discardableResult
    static func create(_ name: String = "我的颜色") -> ColorPalette {
        let p = ColorPalette(name: PaletteText.uniqueName(name, existing: all.map(\.name)))
        Settings.palettes = all + [p]
        Settings.currentPaletteID = p.id
        return p
    }

    static func update(_ id: UUID, _ change: (inout ColorPalette) -> Void) {
        var list = all
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        Settings.palettes = list
    }

    static func rename(_ id: UUID, _ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    static func delete(_ id: UUID) {
        Settings.palettes = all.filter { $0.id != id }
        if Settings.currentPaletteID == id { Settings.currentPaletteID = all.first?.id }
    }

    /// ⌘1 按 S：存进最近打开的调色板（一个都没有就建"我的颜色"）。返回存进哪个、是不是新加的（已经有了就不再加）
    @discardableResult
    static func save(_ value: Int) -> (palette: ColorPalette, added: Bool) {
        let target = current ?? create()
        var added = false
        update(target.id) { added = $0.add(value) }
        Settings.currentPaletteID = target.id
        return (all.first { $0.id == target.id } ?? target, added)
    }
}

/// 调色板小窗口：上面挑调色板（新建、改名、删除），中间是颜色（色块、名字、HEX、RGB、复制），
/// 下面加颜色（取色、打 HEX、最近的颜色）和导出（复制成纯文字 / CSS 变量 / JSON）
@MainActor
final class PaletteWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let window: EditableWindow
    let picker = NSPopUpButton()
    let table = NSTableView()
    let hexField = NSTextField()
    let recentRow = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "还没有颜色：点\u{201C}取色\u{201D}、打一个 HEX，或者点下面最近取过的颜色")
    private(set) var recentButtons: [NSButton] = []
    /// 复制到哪（自检里换成私有剪贴板）
    var pasteboard: NSPasteboard = .general
    /// 自检时 false：复制后不弹提示、打错 HEX 不出声
    var showsToast = true
    var onClose: (() -> Void)?

    /// 现在看着的那个调色板
    var palette: ColorPalette? { Palettes.current }

    /// 开着的那个（菜单"调色板…"再点一次就拿到前面来；⌘1 按 S 存了以后刷新它）
    private(set) static var visible: PaletteWindow?

    static func showShared() {
        if let w = visible { w.show(); return }
        let w = PaletteWindow()
        w.onClose = { visible = nil }
        visible = w
        w.show()
    }

    override init() {
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "调色板"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        reload()
    }

    // MARK: 界面

    private func build() {
        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let top = NSStackView(views: [NSTextField(labelWithString: "调色板"), picker,
                                      ClosureButton(title: "新建") { [weak self] in self?.createPalette() },
                                      ClosureButton(title: "改名…") { [weak self] in self?.askRename() },
                                      ClosureButton(title: "删除…") { [weak self] in self?.askDelete() }])
        top.spacing = 8

        for (id, title, width) in [("swatch", "", 32.0), ("name", "名字（双击起名）", 150.0), ("hex", "HEX", 80.0),
                                   ("rgb", "RGB", 100.0), ("copy", "", 56.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 2)          // 系统默认列间隔 17 点，五列放不下
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle  // 多出来的给"复制"那列，它一直看得见
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = Theme.small()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: 10),
        ])

        hexField.placeholderString = "#FF3B30"
        hexField.delegate = self
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let add = NSStackView(views: [ClosureButton(title: "取色") { [weak self] in self?.sample() },
                                      hexField, ClosureButton(title: "加进来") { [weak self] in self?.addTypedHex() },
                                      NSView(),
                                      ClosureButton(title: "删掉选中的") { [weak self] in self?.removeSelected() },
                                      ClosureButton(title: "导出 ▾") { [weak self] in self?.showExportMenu() }])
        add.spacing = 8
        add.translatesAutoresizingMaskIntoConstraints = false
        add.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let recentTitle = NSTextField(labelWithString: "最近取过的颜色（点一下加进来）")
        recentTitle.font = Theme.small()
        recentTitle.textColor = .secondaryLabelColor
        recentRow.spacing = 4

        let stack = NSStackView(views: [top, scroll, add, recentTitle, recentRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        reload()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let list = Palettes.all
        picker.removeAllItems()
        picker.addItems(withTitles: list.map { "\($0.name)（\($0.colors.count)）" })
        if let current = palette, let i = list.firstIndex(where: { $0.id == current.id }) { picker.selectItem(at: i) }
        picker.isEnabled = !list.isEmpty
        table.reloadData()
        emptyLabel.isHidden = !(palette?.colors.isEmpty ?? true)
        if list.isEmpty { emptyLabel.stringValue = "还没有调色板：⌘1 取色时按 S，或者点\u{201C}新建\u{201D}" }
        else { emptyLabel.stringValue = "还没有颜色：点\u{201C}取色\u{201D}、打一个 HEX，或者点下面最近取过的颜色" }
        reloadRecent()
    }

    private func reloadRecent() {
        for v in recentRow.arrangedSubviews { recentRow.removeArrangedSubview(v); v.removeFromSuperview() }
        recentButtons = Settings.recentColors.map { value in
            let (r, g, b) = ColorHistory.unpack(value)
            let button = ClosureButton(title: "") { [weak self] in self?.add(value) }
            button.isBordered = false
            button.image = Self.swatch(r, g, b, side: 18)
            button.toolTip = ColorText.hex(r, g, b)
            return button
        }
        for b in recentButtons { recentRow.addArrangedSubview(b) }
        if recentButtons.isEmpty {
            let none = NSTextField(labelWithString: "（还没有：⌘1 截图时指着颜色按 C 或 S）")
            none.font = Theme.small()
            none.textColor = .tertiaryLabelColor
            recentRow.addArrangedSubview(none)
        }
    }

    // MARK: 调色板：新建、改名、删除、换一个

    @objc func pickerChanged() {
        let list = Palettes.all
        guard list.indices.contains(picker.indexOfSelectedItem) else { return }
        Settings.currentPaletteID = list[picker.indexOfSelectedItem].id
        reload()
    }

    @discardableResult
    func createPalette(named name: String = "新调色板") -> ColorPalette {
        let p = Palettes.create(name)
        reload()
        return p
    }

    func renameCurrent(to name: String) {
        guard let p = palette else { return }
        Palettes.rename(p.id, name)
        reload()
    }

    func deleteCurrent() {
        guard let p = palette else { return }
        Palettes.delete(p.id)
        reload()
    }

    private func askRename() {
        guard let p = palette else { return }
        let alert = NSAlert()
        alert.messageText = "给调色板改个名字"
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = p.name
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.renameCurrent(to: field.stringValue) } }
        }
    }

    private func askDelete() {
        guard let p = palette else { return }
        let alert = NSAlert()
        alert.messageText = "删掉调色板「\(p.name)」？"
        alert.informativeText = "里面的 \(p.colors.count) 个颜色也一起删掉（最近取过的颜色不受影响）。"
        alert.addButton(withTitle: "删掉")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.deleteCurrent() } }
        }
    }

    // MARK: 颜色：加、起名、删、复制

    /// 加进现在这个调色板（一个都没有就先建"我的颜色"）；已经有了返回 false
    @discardableResult
    func add(_ value: Int) -> Bool {
        let target = palette ?? Palettes.create()
        var added = false
        Palettes.update(target.id) { added = $0.add(value) }
        reload()
        if added, let p = palette { table.selectRowIndexes(IndexSet(integer: p.colors.count - 1), byExtendingSelection: false) }
        return added
    }

    /// 打的 HEX 加进来；打得不对返回 false（输入框标红一下）
    @discardableResult
    func addTypedHex() -> Bool {
        guard let v = PaletteText.parseHex(hexField.stringValue) else {
            if !hexField.stringValue.isEmpty && showsToast { NSSound.beep() }   // 自检时不出声
            return false
        }
        add(v)
        hexField.stringValue = ""
        return true
    }

    /// 系统自带的取色放大镜：指哪取哪（颜色换成 sRGB，和 ⌘1 取色一样）
    private func sample() {
        NSColorSampler().show { [weak self] color in
            MainActor.assumeIsolated {
                guard let c = color?.usingColorSpace(.sRGB) else { return }
                let v = ColorHistory.pack(Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                                          Int((c.blueComponent * 255).rounded()))
                RecentColors.record(ColorHistory.unpack(v).0, ColorHistory.unpack(v).1, ColorHistory.unpack(v).2)
                self?.add(v)
            }
        }
    }

    func setName(row: Int, _ name: String) {
        guard let p = palette, p.colors.indices.contains(row) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        Palettes.update(p.id) { $0.colors[row].name = trimmed.isEmpty ? nil : trimmed }
        reload()
    }

    func removeSelected() {
        guard let p = palette else { return }
        let rows = table.selectedRowIndexes.filter { p.colors.indices.contains($0) }
        guard !rows.isEmpty else { return }
        Palettes.update(p.id) { pal in for i in rows.sorted(by: >) { pal.colors.remove(at: i) } }
        reload()
    }

    /// 一行后面的"复制"：复制 HEX；按住 ⌥ 复制 RGB
    func copyRow(_ row: Int, rgb: Bool = false) {
        guard let p = palette, p.colors.indices.contains(row) else { return }
        let (r, g, b) = ColorHistory.unpack(p.colors[row].value)
        copy(rgb ? ColorText.rgb(r, g, b) : ColorText.hex(r, g, b), what: "颜色")
    }

    // MARK: 导出

    func exportText(_ format: PaletteText.Format) -> String? { palette.map { PaletteText.export($0, as: format) } }

    func copyExport(_ format: PaletteText.Format) {
        guard let text = exportText(format) else { return }
        copy(text, what: format.title)
    }

    func exportMenu() -> NSMenu {
        let menu = NSMenu()
        for f in PaletteText.Format.allCases {
            menu.addItem(ActionMenuItem(f.menuTitle) { [weak self] in self?.copyExport(f) })
        }
        return menu
    }

    private func showExportMenu() {
        guard let content = window.contentView, palette != nil else { return }
        let mouse = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        exportMenu().popUp(positioning: nil, at: mouse, in: content)
    }

    private func copy(_ text: String, what: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if showsToast { Toast.show("✓ 已复制\(what)") }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { palette?.colors.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let p = palette, p.colors.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let c = p.colors[row]
        let (r, g, b) = ColorHistory.unpack(c.value)
        switch id {
        case "swatch":
            let v = NSImageView(image: Self.swatch(r, g, b, side: 20))
            return v
        case "name":
            let field = NSTextField(string: c.name ?? "")
            field.placeholderString = "双击起名"
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.tag = row
            field.delegate = self
            return Self.centered(field)
        case "copy":
            let button = ClosureButton(title: "复制") { [weak self] in
                self?.copyRow(row, rgb: NSEvent.modifierFlags.contains(.option))
            }
            button.controlSize = .small
            button.toolTip = "复制 HEX；按住 ⌥ 复制 RGB"
            return button
        default:
            let label = NSTextField(labelWithString: id == "hex" ? ColorText.hex(r, g, b) : ColorText.rgb(r, g, b))
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.isSelectable = true
            return Self.centered(label)
        }
    }

    /// 字在一行里上下居中
    private static func centered(_ field: NSTextField) -> NSView {
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = field
        return cell
    }

    /// 名字打完（回车或点别处）：存下
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === hexField {
            if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue { addTypedHex() }
            return
        }
        setName(row: field.tag, field.stringValue)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        if NSApp.modalWindow == nil { NSApp.hide(nil) }
    }

    /// 小色块（圆角方块，加一圈细边，白色也看得见）
    static func swatch(_ r: Int, _ g: Int, _ b: Int, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
