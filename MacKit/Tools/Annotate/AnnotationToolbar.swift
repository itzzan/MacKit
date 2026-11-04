import AppKit

/// 带闭包的小按钮
@MainActor
final class ToolbarButton: NSButton {
    private let handler: @MainActor () -> Void
    var isSelectedLook = false { didSet { refreshLook() } }

    init(symbol: String? = nil, title: String? = nil, tip: String, size: CGFloat = 28, width: CGFloat? = nil,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: width ?? size, height: size))
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            self.image = image.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            imagePosition = .imageOnly
        }
        if let title {
            self.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        }
        toolTip = tip
        isBordered = false
        contentTintColor = .white
        refusesFirstResponder = true
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width ?? size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        if let symbol, let title, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            self.image = image.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            imagePosition = .imageLeading
            self.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @MainActor @objc private func fire() { handler() }

    func setSymbol(_ symbol: String, tip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        toolTip = tip
    }

    private func refreshLook() {
        layer?.backgroundColor = isSelectedLook ? NSColor.white.withAlphaComponent(0.28).cgColor : nil
    }
}

/// 颜色小圆点
@MainActor
final class ColorSwatch: NSButton {
    let color: AnnotationColor
    private let handler: @MainActor () -> Void
    var isSelectedLook = false { didSet { layer?.borderWidth = isSelectedLook ? 2.5 : 1 } }

    init(color: AnnotationColor, handler: @escaping @MainActor () -> Void) {
        self.color = color
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        title = ""
        isBordered = false
        refusesFirstResponder = true
        toolTip = color.title
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @MainActor @objc private func fire() { handler() }
}

/// 截图框旁边的工具栏：上面一排工具和操作，选了工具后下面多一排颜色和粗细
@MainActor
final class AnnotationToolbar: NSView {
    enum Mode {
        case screenshot      // 截图：📌 贴图、💾 另存、✕ 取消、✓ 完成
        case pin             // 贴图上标注：✕ 放弃这次画的、✓ 完成
    }

    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((AnnotationColor) -> Void)?
    var onSize: ((AnnotationSize) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private(set) var toolButtons: [AnnotationTool: ToolbarButton] = [:]
    private var swatches: [ColorSwatch] = []
    private var sizeButtons: [ToolbarButton] = []
    private var undoButton: ToolbarButton!
    private var redoButton: ToolbarButton!
    private let propertyRow = NSStackView()
    private let stack = NSStackView()
    let mode: Mode
    private(set) var hasPinAndSave = true

    /// standalone：工具栏单独放在一个透明小窗口里（贴图用），背景要透出窗口后面的东西
    init(mode: Mode = .screenshot, standalone: Bool = false) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = standalone ? .behindWindow : .withinWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        var tools: [NSView] = []
        for tool in AnnotationTool.allCases {
            let button = ToolbarButton(symbol: tool.symbol, tip: "\(tool.title)（\(tool.key.uppercased())）") { [weak self] in
                self?.onTool?(tool)
            }
            toolButtons[tool] = button
            tools.append(button)
        }
        undoButton = ToolbarButton(symbol: "arrow.uturn.backward", tip: "撤销（⌘Z）") { [weak self] in self?.onUndo?() }
        redoButton = ToolbarButton(symbol: "arrow.uturn.forward", tip: "重做（⇧⌘Z）") { [weak self] in self?.onRedo?() }
        let pin = ToolbarButton(symbol: "pin", tip: "贴图：钉在原位置（⌘2）") { [weak self] in self?.onPin?() }
        let save = ToolbarButton(symbol: "square.and.arrow.down", tip: "另存为（⌘S）") { [weak self] in self?.onSave?() }
        let cancel = ToolbarButton(symbol: "xmark", tip: mode == .pin ? "放弃这次画的（Esc）" : "取消（Esc）") { [weak self] in
            self?.onCancel?()
        }
        let done = ToolbarButton(symbol: "checkmark", tip: mode == .pin ? "完成标注（回车）" : "完成：复制并保存（回车）") { [weak self] in
            self?.onDone?()
        }
        done.contentTintColor = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)

        let actions: [NSView] = mode == .pin ? [cancel, done] : [pin, save, cancel, done]
        hasPinAndSave = mode == .screenshot
        let mainRow = NSStackView(views: tools + [Self.divider(), undoButton, redoButton, Self.divider()] + actions)
        mainRow.orientation = .horizontal
        mainRow.spacing = 2

        for color in AnnotationColor.allCases {
            let swatch = ColorSwatch(color: color) { [weak self] in self?.onColor?(color) }
            swatches.append(swatch)
        }
        for size in AnnotationSize.allCases {
            let button = ToolbarButton(title: size.title, tip: "粗细：\(size.title)") { [weak self] in self?.onSize?(size) }
            sizeButtons.append(button)
        }
        propertyRow.setViews(swatches + [Self.divider()] + sizeButtons, in: .leading)
        propertyRow.orientation = .horizontal
        propertyRow.spacing = 6
        propertyRow.isHidden = true

        stack.setViews([mainRow, propertyRow], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    func update(tool: AnnotationTool?, color: AnnotationColor, size: AnnotationSize, canUndo: Bool, canRedo: Bool) {
        for (t, button) in toolButtons { button.isSelectedLook = t == tool }
        for swatch in swatches { swatch.isSelectedLook = swatch.color == color }
        for (i, button) in sizeButtons.enumerated() { button.isSelectedLook = i == size.rawValue }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.alphaValue = canRedo ? 1 : 0.35
        propertyRow.isHidden = tool == nil
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }

    var isShowingProperties: Bool { !propertyRow.isHidden }
}
