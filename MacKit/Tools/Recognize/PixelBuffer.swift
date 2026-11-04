import CoreGraphics

/// 冻住的整屏画面的像素（换算成 sRGB、每像素 4 字节），放大镜取色和测量找边都从这里读
final class PixelBuffer {
    let width: Int
    let height: Int
    private var data: [UInt8]

    init?(image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))      // 这一步顺带把颜色换算成 sRGB
            return true
        }
        guard ok else { return nil }
    }

    /// 像素坐标，左上原点（CGContext 的内存是从上往下一行行排的）
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}
