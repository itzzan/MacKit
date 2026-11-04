import AppKit

/// 识别结果的小窗口：字能直接改；"去掉换行"把一段话接回一行；"复制"；有二维码时显示内容，网址能打开
@MainActor
final class OCRResultWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let textView = NSTextView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private(set) var buttons: [String: NSButton] = [:]
    let result: OCRResult
    var onClose: (() -> Void)?

    init(result: OCRResult) {
        self.result = result
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 380),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 380, height: 220)
        window.title = result.lines.isEmpty && result.codes.isEmpty ? "没认出文字" : "识别结果 — \(result.text.count) 个字"

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Theme.body(.regular)
        textView.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.3)]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = result.text
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.lineBreakMode = .byTruncatingMiddle
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.isSelectable = true
        if let code = result.codes.first { codeLabel.stringValue = "二维码：\(code)" }
        codeLabel.isHidden = result.codes.isEmpty

        let actions: [(String, String, Selector)] = [
            ("join", "去掉换行", #selector(joinLines)),
            ("copy", "复制", #selector(copyText)),
            ("copyCode", "复制二维码内容", #selector(copyCode)),
            ("open", "打开链接", #selector(openLink)),
        ]
        var views: [NSView] = []
        for (key, title, selector) in actions {
            let b = NSButton(title: title, target: self, action: selector)
            b.bezelStyle = .rounded
            buttons[key] = b
            views.append(b)
        }
        buttons["copy"]?.keyEquivalent = "\r"
        buttons["copyCode"]?.isHidden = result.codes.isEmpty
        buttons["open"]?.isHidden = result.codes.first.flatMap(OCRText.url(in:)) == nil
        status.textColor = .secondaryLabelColor
        status.font = Theme.small()
        status.stringValue = result.lines.isEmpty ? (result.codes.isEmpty ? "这块里没认出文字" : "") : "已复制到剪贴板"
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: views + [status])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.detachesHiddenViews = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [scroll, codeLabel, bar] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            codeLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            codeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: codeLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        window.contentView = root
    }

    /// present = false 只给自检用
    func show(present: Bool = true) {
        guard present else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    // MARK: 按钮

    @objc func joinLines() {
        textView.string = OCRText.joinLines(textView.string.components(separatedBy: .newlines))
        status.stringValue = "已接成一段，点「复制」复制"
    }

    @objc func copyText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
        status.stringValue = "✓ 已复制 \(textView.string.count) 个字"
    }

    @objc private func copyCode() {
        guard let code = result.codes.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        status.stringValue = "✓ 已复制二维码内容"
    }

    @objc private func openLink() {
        if let url = result.codes.first.flatMap(OCRText.url(in:)) { NSWorkspace.shared.open(url) }
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}
