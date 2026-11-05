import AppKit

/// 带闭包的小按钮（台阶 10：统一样子，鼠标放上去会亮、按下有反馈、选中是主题色底）
@MainActor
final class ToolbarButton: NSButton {
    enum Style {
        case plain        // 只有图标或文字，透明底
        case primary      // 主按钮：主题色底（完成、开始录制、继续）
        case danger       // 停止：红底
        case secondary    // 次要按钮：淡淡的底（提示条里的按钮）
    }

    private let handler: @MainActor () -> Void
    var style: Style { didSet { refreshLook() } }
    /// 选中的工具、打开的开关
    var isSelectedLook = false { didSet { refreshLook() } }
    /// 鼠标在上面（样张里也直接设）
    var isHoveredLook = false { didSet { refreshLook() } }
    var isPressedLook = false { didSet { refreshLook() } }
    private var tracking: NSTrackingArea?
    private var widthConstraint: NSLayoutConstraint?
    private let fixedWidth: CGFloat?
    private let hasSymbol: Bool
    private var titleText: String?

    init(symbol: String? = nil, title: String? = nil, tip: String, size: CGFloat = Theme.buttonSize, width: CGFloat? = nil,
         style: Style = .plain, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.style = style
        fixedWidth = width
        hasSymbol = symbol != nil
        titleText = title
        super.init(frame: CGRect(x: 0, y: 0, width: width ?? size, height: size))
        toolTip = tip
        isBordered = false
        if title == nil { self.title = "" }
        (cell as? NSButtonCell)?.highlightsBy = []          // 按下的样子自己画
        refusesFirstResponder = true
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = Theme.buttonRadius
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: size).isActive = true
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            self.image = image.withSymbolConfiguration(.init(pointSize: title == nil ? 14 : 12, weight: title == nil ? .medium : .semibold))
            imagePosition = title == nil ? .imageOnly : .imageLeading
            imageHugsTitle = true                              // 图标紧挨着文字，一起居中
        }
        applyTitle()
        let w = widthConstraint(for: size)
        w.isActive = true
        widthConstraint = w
        refreshLook()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @MainActor @objc private func fire() { handler() }

    func setTitle(_ title: String) {
        titleText = title
        applyTitle()
        if fixedWidth == nil { widthConstraint?.constant = autoWidth() }
    }

    func setSymbol(_ symbol: String, tip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: titleText == nil ? 14 : 12, weight: titleText == nil ? .medium : .semibold))
        toolTip = tip
    }

    override var contentTintColor: NSColor? {
        didSet { applyTitle() }
    }

    private func applyTitle() {
        guard let titleText else { return }
        let color = contentTintColor ?? Theme.text
        attributedTitle = NSAttributedString(string: (hasSymbol ? " " : "") + titleText, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.bodySize, weight: .semibold), .foregroundColor: color])
    }

    /// 带文字的按钮没给宽度时：按文字长短自己算
    private func autoWidth() -> CGFloat {
        guard let titleText else { return Theme.buttonSize }
        let text = ((hasSymbol ? " " : "") + titleText) as NSString
        let w = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: Theme.bodySize, weight: .semibold)]).width
        return ceil(w + (hasSymbol ? 16 : 0) + 20)
    }

    private func widthConstraint(for size: CGFloat) -> NSLayoutConstraint {
        widthAnchor.constraint(equalToConstant: fixedWidth ?? (titleText == nil ? size : autoWidth()))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHoveredLook = true }
    override func mouseExited(with event: NSEvent) { isHoveredLook = false }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressedLook = flag
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    /// 底色：选中 / 主按钮 / 停止 / 次要 / 普通，再叠上鼠标放上去、按下去的变化
    var fillColor: NSColor? {
        switch style {
        case .primary: return isPressedLook ? Theme.accentPressed : isHoveredLook ? Theme.accent.blended(withFraction: 0.12, of: .white) : Theme.accent
        case .danger: return isPressedLook ? Theme.recordPressed : isHoveredLook ? Theme.record.blended(withFraction: 0.12, of: .white) : Theme.record
        case .secondary: return isPressedLook ? Theme.pressedFill.withAlphaComponent(0.3) : isHoveredLook ? Theme.pressedFill : Theme.secondaryFill
        case .plain:
            if isSelectedLook { return isPressedLook ? Theme.accentPressed : Theme.accent }
            return isPressedLook ? Theme.pressedFill : isHoveredLook ? Theme.hoverFill : nil
        }
    }

    private func refreshLook() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = fillColor?.cgColor
        CATransaction.commit()
        if contentTintColor == nil || contentTintColor == Theme.text { contentTintColor = Theme.text }
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
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
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
    var onRecognize: (() -> Void)?
    var onLongShot: (() -> Void)?
    var onBeautify: (() -> Void)?
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

        let background = Theme.surface(withinWindow: !standalone)
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
        let recognize = ToolbarButton(symbol: "text.viewfinder", tip: "识别文字（框里的字复制出来）") { [weak self] in
            self?.onRecognize?()
        }
        let longShot = ToolbarButton(symbol: "rectangle.expand.vertical", tip: "长截图：框不动，往下滚动拼成一张长图") { [weak self] in
            self?.onLongShot?()
        }
        let beautify = ToolbarButton(symbol: "wand.and.stars", tip: "美化：加背景、圆角、阴影") { [weak self] in
            self?.onBeautify?()
        }
        let cancel = ToolbarButton(symbol: "xmark", tip: mode == .pin ? "放弃这次画的（Esc）" : "取消（Esc）") { [weak self] in
            self?.onCancel?()
        }
        let done = ToolbarButton(symbol: "checkmark", tip: mode == .pin ? "完成标注（回车）" : "完成：复制并保存（回车）",
                                 style: .primary) { [weak self] in
            self?.onDone?()
        }

        let actions: [NSView] = mode == .pin ? [cancel, done] : [recognize, longShot, beautify, pin, save, cancel, done]
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

        // 右边、下边贴边的约束让一步：刚造出来时工具栏还是 0 大小（下面 update 才按内容定大小），
        // 硬贴会和按钮的固定宽度打架，系统日志里刷满"约束冲突"（台阶 14 查到）
        let soft = [stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                    background.trailingAnchor.constraint(equalTo: trailingAnchor),
                    background.bottomAnchor.constraint(equalTo: bottomAnchor)]
        for c in soft { c.priority = .init(999) }
        NSLayoutConstraint.activate(soft + [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
        ])
        setFrameSize(stack.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func divider() -> NSView { Theme.dividerView() }

    /// showProperties：没选工具、但选中了一个画好的东西时，也要露出颜色和粗细（台阶 12）
    func update(tool: AnnotationTool?, color: AnnotationColor, size: AnnotationSize, canUndo: Bool, canRedo: Bool,
                showProperties: Bool? = nil) {
        for (t, button) in toolButtons { button.isSelectedLook = t == tool }
        for swatch in swatches { swatch.isSelectedLook = swatch.color == color }
        for (i, button) in sizeButtons.enumerated() { button.isSelectedLook = i == size.rawValue }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.alphaValue = canRedo ? 1 : 0.35
        propertyRow.isHidden = !(showProperties ?? (tool != nil))
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }

    var isShowingProperties: Bool { !propertyRow.isHidden }
}
