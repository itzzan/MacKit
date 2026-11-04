import AppKit

/// 当前屏幕上的普通窗口，从最前到最后排列，用于"单击截窗口"
enum WindowList {
    static func currentFrames() -> [CGRect] { current().map(\.frame) }

    /// 带窗口编号（录屏录某个窗口要用）
    static func current() -> [(frame: CGRect, id: CGWindowID)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,                 // 只要普通窗口
                  (w[kCGWindowOwnerPID as String] as? pid_t) != myPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            return (frame, (w[kCGWindowNumber as String] as? CGWindowID) ?? 0)
        }
    }
}
