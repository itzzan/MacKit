import Vision

/// 识别结果：文字（从上到下一行行）和二维码内容
struct OCRResult {
    var lines: [String]
    var codes: [String]
    var text: String { lines.joined(separator: "\n") }
}

/// 用苹果的 Vision 在这台电脑上识别文字和二维码（不联网）
enum TextRecognizer {
    /// 准确模式才认中文（快速模式只有 6 种西文）。
    /// 2026-11-04 实测：中文必须排第一；英文排第一或"自动判断"时中文、中英混排的短句会认成乱码
    static let languages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    static func recognize(_ image: CGImage) async -> OCRResult {
        await Task.detached(priority: .userInitiated) { () -> OCRResult in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.recognitionLanguages = languages
            let codeRequest = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([textRequest, codeRequest])
            let observations = (textRequest.results ?? []).sorted(by: readingOrder)
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }.map(OCRText.normalizePunctuation)
            let codes = (codeRequest.results ?? []).compactMap(\.payloadStringValue)
            return OCRResult(lines: lines, codes: codes)
        }.value
    }

    /// 从上到下；差不多同一行的从左到右（Vision 的框是左下原点、0–1）
    nonisolated static func readingOrder(_ a: VNRecognizedTextObservation, _ b: VNRecognizedTextObservation) -> Bool {
        let tolerance = min(a.boundingBox.height, b.boundingBox.height) / 2
        if abs(a.boundingBox.midY - b.boundingBox.midY) < tolerance { return a.boundingBox.minX < b.boundingBox.minX }
        return a.boundingBox.midY > b.boundingBox.midY
    }
}
