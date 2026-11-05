import AppKit

/// 识别结果的小窗口：字能直接改；"去掉换行"把一段话接回一行；"复制"；有二维码时显示内容，网址能打开。
/// 台阶 15：点"翻译"在下半部分出译文（方向自动：中文 → 英文，别的 → 中文；旁边小菜单能换），翻好自动复制译文
@MainActor
final class OCRResultWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let textView = NSTextView()
    let translationView = NSTextView()
    private let translationScroll = NSScrollView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    let translateStatus = NSTextField(labelWithString: "")
    let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var buttons: [String: NSButton] = [:]
    let result: OCRResult
    var onClose: (() -> Void)?
    /// 复制到哪（自检用私有剪贴板）
    var pasteboard: NSPasteboard = .general
    private let translator: TextTranslating
    /// 往哪种语言翻；你在小菜单里选过就不再自动换
    private(set) var target: String
    private(set) var userPickedTarget = false
    private(set) var isTranslating = false
    var hasTranslation: Bool { !translationScroll.isHidden }

    init(result: OCRResult, translator: TextTranslating? = nil) {
        self.result = result
        self.translator = translator ?? SystemTranslator()
        target = TranslateLanguages.defaultTarget(forDetected: LanguageGuess.detect(result.text))
        window = EditableWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 380),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 460, height: 240)
        window.title = result.lines.isEmpty && result.codes.isEmpty ? "没认出文字" : "识别结果 — \(result.text.count) 个字"
        build()
    }

    private static func textArea(_ tv: NSTextView, in scroll: NSScrollView) {
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Theme.body(.regular)
        tv.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.3)]
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
    }

    private func build() {
        let scroll = NSScrollView()
        Self.textArea(textView, in: scroll)
        textView.string = result.text
        Self.textArea(translationView, in: translationScroll)
        translationScroll.isHidden = true
        translationScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        codeLabel.lineBreakMode = .byTruncatingMiddle
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.isSelectable = true
        if let code = result.codes.first { codeLabel.stringValue = "二维码：\(code)" }
        codeLabel.isHidden = result.codes.isEmpty

        func button(_ key: String, _ title: String, _ selector: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: selector)
            b.bezelStyle = .rounded
            buttons[key] = b
            return b
        }
        let row1 = [button("join", "去掉换行", #selector(joinLines)), button("copy", "复制", #selector(copyText)),
                    button("copyCode", "复制二维码内容", #selector(copyCode)), button("open", "打开链接", #selector(openLink))]
        buttons["copy"]?.keyEquivalent = "\r"
        buttons["copyCode"]?.isHidden = result.codes.isEmpty
        buttons["open"]?.isHidden = result.codes.first.flatMap(OCRText.url(in:)) == nil
        status.textColor = .secondaryLabelColor
        status.font = Theme.small()
        status.stringValue = result.lines.isEmpty ? (result.codes.isEmpty ? "这块里没认出文字" : "") : "已复制到剪贴板"
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (code, name) in TranslateLanguages.targets { targetPopup.addItem(withTitle: "翻成\(name)"); targetPopup.lastItem?.representedObject = code }
        targetPopup.target = self
        targetPopup.action = #selector(targetPicked)
        selectTargetInPopup()
        let row2 = [button("translate", "翻译", #selector(translate)), targetPopup,
                    button("copyTranslation", "复制译文", #selector(copyTranslation))]
        buttons["copyTranslation"]?.isHidden = true
        buttons["translate"]?.isEnabled = !result.text.isEmpty
        translateStatus.textColor = .secondaryLabelColor
        translateStatus.font = Theme.small()
        translateStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translateStatus.stringValue = "用系统自带的翻译，在你电脑上翻"

        func bar(_ views: [NSView]) -> NSStackView {
            let b = NSStackView(views: views)
            b.orientation = .horizontal
            b.spacing = 8
            b.detachesHiddenViews = true
            b.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            return b
        }
        let stack = NSStackView(views: [scroll, codeLabel, bar(row1 + [status]), translationScroll, bar(row2 + [translateStatus])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        for v in [scroll, translationScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
        codeLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // 系统的翻译要挂在窗口里的一块小视图上（看不见）
        if let host = translator.hostView {
            host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            root.addSubview(host)
        }
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
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        status.stringValue = "✓ 已复制 \(textView.string.count) 个字"
    }

    @objc private func copyCode() {
        guard let code = result.codes.first else { return }
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        status.stringValue = "✓ 已复制二维码内容"
    }

    @objc private func openLink() {
        if let url = result.codes.first.flatMap(OCRText.url(in:)) { NSWorkspace.shared.open(url) }
    }

    // MARK: 翻译（台阶 15）

    private func selectTargetInPopup() {
        if let i = targetPopup.itemArray.firstIndex(where: { $0.representedObject as? String == target }) { targetPopup.selectItem(at: i) }
    }

    /// 小菜单里换了语言：记住是你选的，马上按新语言再翻
    @objc func targetPicked() {
        guard let code = targetPopup.selectedItem?.representedObject as? String else { return }
        target = code
        userPickedTarget = true
        if hasTranslation || isTranslating { translate() }
    }

    func pickTarget(_ code: String) {
        guard let i = targetPopup.itemArray.firstIndex(where: { $0.representedObject as? String == code }) else { return }
        targetPopup.selectItem(at: i)
        targetPicked()
    }

    /// 按原文框里现在的字翻（改过错字就按改过的翻）
    @objc func translate() {
        let text = textView.string
        let source = LanguageGuess.detect(text)
        if !userPickedTarget {
            target = TranslateLanguages.defaultTarget(forDetected: source)
            selectTargetInPopup()
        }
        let goal = target
        isTranslating = true
        buttons["translate"]?.isEnabled = false
        translateStatus.stringValue = "正在翻成\(TranslateLanguages.name(of: goal))…"
        Task { @MainActor in
            defer {
                self.isTranslating = false
                self.buttons["translate"]?.isEnabled = true
            }
            do {
                let out = try await self.translator.translate(text, from: source, to: goal)
                guard goal == self.target else { return }            // 翻的过程中又换了语言：等新的那次
                self.showTranslation(out)
            } catch is CancellationError {
                return
            } catch {
                self.translateStatus.stringValue = error.localizedDescription
                Log.capture.notice("ocr translate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showTranslation(_ text: String) {
        if translationScroll.isHidden {
            translationScroll.isHidden = false
            buttons["copyTranslation"]?.isHidden = false
            buttons["copy"]?.title = "复制原文"
            var frame = window.frame
            frame.size.height += 156
            frame.origin.y -= 156
            window.setFrame(frame, display: true)
        }
        translationView.string = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        translateStatus.stringValue = "✓ 已翻成\(TranslateLanguages.name(of: target))，译文已复制"
    }

    @objc func copyTranslation() {
        pasteboard.clearContents()
        pasteboard.setString(translationView.string, forType: .string)
        translateStatus.stringValue = "✓ 已复制译文"
    }

    func windowWillClose(_ notification: Notification) {
        translator.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }
}
