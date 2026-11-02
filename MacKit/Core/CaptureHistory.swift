import AppKit

/// 最近一次截图：图片、在屏幕上的位置、复制到剪贴板后的剪贴板编号。
/// 贴图时如果剪贴板没变过，就把图贴回截取的原位置。
struct CaptureRecord {
    let image: CGImage
    let pointSize: NSSize
    let globalFrame: CGRect          // Cocoa 全局坐标（点）
    let pasteboardName: NSPasteboard.Name
    let changeCount: Int
}

@MainActor
enum CaptureHistory {
    static var last: CaptureRecord?

    static func record(image: CGImage, pointSize: NSSize, globalFrame: CGRect, pasteboard: NSPasteboard) {
        last = CaptureRecord(image: image, pointSize: pointSize, globalFrame: globalFrame,
                             pasteboardName: pasteboard.name, changeCount: pasteboard.changeCount)
    }

    /// 剪贴板自从截图后没被别人改过，返回那次截图
    static func matching(_ pasteboard: NSPasteboard) -> CaptureRecord? {
        guard let last, last.pasteboardName == pasteboard.name,
              last.changeCount == pasteboard.changeCount else { return nil }
        return last
    }
}
