import AppKit

/// App 图标：MacKit --make-iconset <文件夹>（scripts/make-icon.sh 调它，再用 iconutil 打包成 AppIcon.icns）。
/// 用代码画（台阶 10 拍板：不用网上的素材）：深色圆角方块 + 主题色的扳手和螺丝刀，和菜单栏的扳手图标一致
@MainActor
enum IconMaker {
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--make-iconset"), arguments.indices.contains(i + 1) else { exit(2) }
        let folder = URL(fileURLWithPath: arguments[i + 1])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let master = draw(size: 1024) else { print("图标失败"); exit(1) }
        // 系统要的各种尺寸：16、32、128、256、512，每种还有两倍图
        for base in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                let px = base * scale
                guard let image = px == 1024 ? master : resize(master, to: px),
                      write(image, to: folder.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")) else {
                    print("图标失败：\(px)")
                    exit(1)
                }
            }
        }
        print("图标：\(folder.path)")
        exit(0)
    }

    /// 画一张 size×size 的图标（按苹果的图标网格：四周留白，圆角方块）
    static func draw(size: Int) -> CGImage? {
        let s = CGFloat(size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = s / 1024
        let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
        let radius = 185 * k
        let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 底下一点阴影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 深色渐变的方块
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let top = NSColor(srgbRed: 0.24, green: 0.26, blue: 0.31, alpha: 1).cgColor
        let bottom = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }
        ctx.restoreGState()
        // 一圈细细的亮边
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5 * k, dy: 1.5 * k), cornerWidth: radius - 1.5 * k,
                           cornerHeight: radius - 1.5 * k, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(3 * k)
        ctx.strokePath()

        // 扳手和螺丝刀：先画成白色，再用渐变蓝盖上（只盖在图形上）
        let config = NSImage.SymbolConfiguration(pointSize: 430 * k, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return ctx.makeImage() }
        let fit = min(560 * k / symbol.size.width, 560 * k / symbol.size.height)
        let w = symbol.size.width * fit, h = symbol.size.height * fit
        let rect = CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceAtop)
        let light = NSColor(srgbRed: 0.42, green: 0.74, blue: 1.0, alpha: 1).cgColor
        if let blue = CGGradient(colorsSpace: space, colors: [light, Theme.accent.cgColor, Theme.accentPressed.cgColor] as CFArray,
                                 locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(blue, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, to px: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
