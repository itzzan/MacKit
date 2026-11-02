import AppKit
import UniformTypeIdentifiers

/// 剪贴板里能贴出来的东西
enum PinContent {
    case original(CaptureRecord)                 // 刚截的图，贴回原位置
    case image(CGImage, pointSize: NSSize)       // 别处复制来的图片
    case text(String)                            // 文字 → 文字卡片
}

@MainActor
enum PinContentReader {
    /// 按复制来源给的顺序找第一个能贴的：图片文件、图片、文字
    static func read(_ pb: NSPasteboard) -> PinContent? {
        if let record = CaptureHistory.matching(pb) { return .original(record) }

        if let item = pb.pasteboardItems?.first {
            for type in item.types {
                if type == .fileURL {
                    if let link = item.string(forType: .fileURL), let url = URL(string: link),
                       let content = imageFile(url) { return content }
                    continue
                }
                guard let ut = UTType(type.rawValue) else { continue }
                if ut.conforms(to: .image), !ut.conforms(to: .pdf),
                   let data = item.data(forType: type), let content = image(from: data) {
                    return content
                }
                if ut.conforms(to: .text), let text = item.string(forType: .string), hasText(text) {
                    return .text(text)
                }
            }
        }
        // 兜底
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = images.first, let content = image(from: first) { return content }
        if let text = pb.string(forType: .string), hasText(text) { return .text(text) }
        return nil
    }

    private static func hasText(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func imageFile(_ url: URL) -> PinContent? {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let img = NSImage(contentsOf: url) else { return nil }
        return image(from: img)
    }

    private static func image(from data: Data) -> PinContent? {
        guard let img = NSImage(data: data) else { return nil }
        return image(from: img)
    }

    private static func image(from img: NSImage) -> PinContent? {
        var rect = CGRect(origin: .zero, size: img.size)
        guard img.size.width > 0, img.size.height > 0,
              let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        // NSImage.size 已按图片自带的分辨率换成"点"：Retina 截图 1000 像素宽 → 500 点
        return .image(cg, pointSize: img.size)
    }
}

/// 把文字画成一张白底卡片
enum TextCard {
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 1600
    static let padding: CGFloat = 14

    static func render(_ text: String, scale: CGFloat) -> (image: CGImage, pointSize: NSSize)? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributed = NSAttributedString(string: String(text.prefix(5000)), attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
        let box = attributed.boundingRect(with: NSSize(width: maxWidth, height: 100_000),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textW = ceil(min(max(box.width, 20), maxWidth))
        let textH = ceil(min(max(box.height, 18), maxHeight))
        let size = NSSize(width: textW + padding * 2, height: textH + padding * 2)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size          // 必须在建画布之前设：画布按它决定"一个点 = 几个像素"
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        attributed.draw(in: NSRect(x: padding, y: padding, width: textW, height: textH))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        return (image, size)
    }
}
