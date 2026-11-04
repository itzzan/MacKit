import AppKit

/// 带圆角黑底的小文字标签
final class LabelLayer: CALayer {
    private let text = CATextLayer()
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    override init() {
        super.init()
        backgroundColor = Theme.solidFill.cgColor
        cornerRadius = Theme.labelRadius
        borderWidth = 0.5
        borderColor = Theme.border.cgColor
        text.font = Self.font
        text.fontSize = 12
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        addSublayer(text)
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 设置文字，返回标签应有的大小
    func set(_ string: String, scale: CGFloat) -> CGSize {
        let size = (string as NSString).size(withAttributes: [.font: Self.font])
        let padH: CGFloat = 6, padV: CGFloat = 3
        text.string = string
        text.contentsScale = scale
        contentsScale = scale
        text.frame = CGRect(x: padH, y: padV, width: ceil(size.width), height: ceil(size.height))
        return CGSize(width: ceil(size.width) + padH * 2, height: ceil(size.height) + padV * 2)
    }
}
