import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 把一条历史放回剪贴板，必要时替你按一下 ⌘V
@MainActor
enum ClipboardPaster {
    /// 放回剪贴板。plainText = 只放纯文字（去掉格式）。返回是否成功
    @discardableResult
    static func write(_ item: ClipboardItem, plainText: Bool, store: ClipboardStore, to pb: NSPasteboard) -> Bool {
        if plainText, let text = plainString(of: item, store: store) {
            writeText(text, to: pb)
            return true
        }
        var objects: [NSPasteboardItem] = []
        for (index, entries) in item.pasteboardItems.enumerated() {
            let pbItem = NSPasteboardItem()
            for entry in entries {
                if let data = store.data(of: entry) { pbItem.setData(data, forType: NSPasteboard.PasteboardType(entry.type)) }
            }
            if index == 0 { pbItem.setData(Data(), forType: ClipboardReader.restoreMarker) }   // 别再记一遍
            objects.append(pbItem)
        }
        pb.clearContents()
        return pb.writeObjects(objects)
    }

    /// 只放纯文字，带 MacKit 的标记（剪贴板历史不会再记一遍）
    static func writeText(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.declareTypes([.string, ClipboardReader.restoreMarker], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardReader.restoreMarker)
    }

    static func plainString(of item: ClipboardItem, store: ClipboardStore) -> String? {
        guard let entry = item.pasteboardItems.first?.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue }),
              let data = store.data(of: entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 有没有"辅助功能"权限（替你按 ⌘V 要用）
    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    /// 让系统弹出"辅助功能"授权提示，并把 MacKit 加进列表
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 等原来的软件回到前台，再替它按一下 ⌘V
    static func pasteIntoFrontApp() {
        Task { @MainActor in
            let me = ProcessInfo.processInfo.processIdentifier
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier == me {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(60))
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            Log.app.notice("clipboard: pasted into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
        }
    }
}
