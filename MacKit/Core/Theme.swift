import AppKit

/// MacKit 的统一样子（台阶 10）：颜色、圆角、字号、间距都定义在这一处，以后想换只改这里。
/// 规矩：主题色（蓝）= 选中、主按钮、选区；红色只给"正在录制""停止"；黄色只用来提醒；绿色只给"成功"的勾
enum Theme {
    // MARK: 颜色

    /// 主题色：和截图选区框同一个蓝
    static let accent = NSColor(srgbRed: 0.12, green: 0.56, blue: 1.0, alpha: 1)
    static let accentPressed = NSColor(srgbRed: 0.07, green: 0.44, blue: 0.85, alpha: 1)
    /// 正在录制、停止
    static let record = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    static let recordPressed = NSColor(srgbRed: 0.84, green: 0.19, blue: 0.16, alpha: 1)
    /// 提醒（对不上了、贴图穿透中……）
    static let warning = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.24, alpha: 1)
    /// 成功的勾
    static let success = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.45, alpha: 1)

    static let text = NSColor.white
    static let secondaryText = NSColor.white.withAlphaComponent(0.62)
    /// 鼠标放上去、按下去、次要按钮的底
    static let hoverFill = NSColor.white.withAlphaComponent(0.12)
    static let pressedFill = NSColor.white.withAlphaComponent(0.22)
    static let secondaryFill = NSColor.white.withAlphaComponent(0.14)
    static let border = NSColor.white.withAlphaComponent(0.14)
    static let divider = NSColor.white.withAlphaComponent(0.18)
    /// 自己画的深色底（尺寸标签、预览条；还有样张里代替毛玻璃）
    static let solidFill = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.9)

    // MARK: 圆角、尺寸

    static let barRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 7
    static let labelRadius: CGFloat = 5
    static let buttonSize: CGFloat = 28
    static let barInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

    // MARK: 字：两档，数字用等宽

    static let bodySize: CGFloat = 13
    static let smallSize: CGFloat = 11
    static func body(_ weight: NSFont.Weight = .medium) -> NSFont { .systemFont(ofSize: bodySize, weight: weight) }
    static func small(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: smallSize, weight: weight) }
    static func number(_ size: CGFloat = bodySize, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// 样张里毛玻璃画不出来，改用实色（真正显示时是半透明的毛玻璃）
    nonisolated(unsafe) static var solidBars = false

    // MARK: 浮动条

    /// 浮动条的底：深色毛玻璃 + 细边框 + 圆角。withinWindow：工具栏在截图覆盖层里面，透出的是冻住的画面
    @MainActor
    static func surface(radius: CGFloat = barRadius, withinWindow: Bool = false) -> NSView {
        let view: NSView
        if solidBars {
            view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = solidFill.cgColor
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = withinWindow ? .withinWindow : .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            view = effect
        }
        view.appearance = NSAppearance(named: .darkAqua)
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = border.cgColor
        return view
    }

    /// 浮动条的底，content 贴满
    @MainActor
    static func bar(containing content: NSView, radius: CGFloat = barRadius, withinWindow: Bool = false) -> NSView {
        let background = surface(radius: radius, withinWindow: withinWindow)
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// 一排按钮：统一的间距和边距
    @MainActor
    static func row(_ views: [NSView], spacing: CGFloat = 4, insets: NSEdgeInsets = barInsets) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = spacing
        row.edgeInsets = insets
        return row
    }

    /// 按钮之间的竖线
    @MainActor
    static func dividerView() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = divider.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    /// 一行白字
    @MainActor
    static func label(_ text: String, font: NSFont = body(), color: NSColor = Theme.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }
}
