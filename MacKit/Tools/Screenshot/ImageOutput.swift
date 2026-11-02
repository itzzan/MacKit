import AppKit

/// 截好的图：复制到剪贴板、存成文件
enum ImageOutput {
    /// pointSize 是图片在屏幕上的"点"尺寸。写进 PNG 后，Retina 截图粘贴到别处时显示大小正常
    static func pngData(of image: CGImage, pointSize: NSSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    static func copyToClipboard(_ image: CGImage, pointSize: NSSize, png: Data) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// 文件名像 MacKit_2026-10-28_14-03-05.png，同一秒多张会加 -2、-3
    static func save(png: Data, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "MacKit_\(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        try png.write(to: url, options: .atomic)
        return url
    }
}
