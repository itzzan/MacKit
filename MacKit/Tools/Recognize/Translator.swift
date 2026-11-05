import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// 翻译员（台阶 15）：系统自带的那个，自检里换成假的
@MainActor
protocol TextTranslating: AnyObject {
    /// source = nil：让系统自己认
    func translate(_ text: String, from source: String?, to target: String) async throws -> String
    /// 要放进窗口里的那块小视图（系统要在这个窗口上弹"下载语言"的提示）；不需要就是 nil
    var hostView: NSView? { get }
    /// 窗口关了：还没翻完的就不等了
    func cancel()
}

enum TranslateError: LocalizedError, Equatable {
    case empty
    case sameLanguage(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .empty: "没有要翻译的字"
        case .sameLanguage(let name): "已经是\(name)了，换一种语言试试"
        case .unsupported(let name): "系统的翻译不支持翻成\(name)"
        case .failed(let why): "没翻成：\(why)"
        }
    }
}

/// 认出一段字是哪种语言（系统自带的语言识别），比如 zh-Hans、en、ja
enum LanguageGuess {
    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }
}

/// macOS 15 只能从 SwiftUI 里拿到"翻译会话"：这块看不见的小视图挂上系统的翻译任务，
/// 给它一个配置（从哪种语言翻到哪种），它就在电脑上翻好交回来。macOS 26 起能直接调用，到时候再简化
@MainActor
final class TranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var pending: (text: String, continuation: CheckedContinuation<String, Error>)?

    func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        do {
            let response = try await session.translate(job.text)
            job.continuation.resume(returning: response.targetText)
        } catch {
            job.continuation.resume(throwing: TranslateError.failed(error.localizedDescription))
        }
    }

    func cancelPending() {
        pending?.continuation.resume(throwing: CancellationError())
        pending = nil
    }
}

struct TranslationHostView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
    }
}

/// 系统自带的翻译：在你电脑上本地翻，MacKit 不联网；第一次翻某种语言时系统会问要不要下载
@MainActor
final class SystemTranslator: TextTranslating {
    let bridge = TranslationBridge()
    private let host: NSHostingView<TranslationHostView>

    init() {
        host = NSHostingView(rootView: TranslationHostView(bridge: bridge))
        host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var hostView: NSView? { host }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslateError.empty }
        if TranslateLanguages.same(source, target) { throw TranslateError.sameLanguage(TranslateLanguages.name(of: target)) }
        let dst = Locale.Language(identifier: target)
        let src = source.map { Locale.Language(identifier: $0) }
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let src {
            status = await availability.status(from: src, to: dst)
        } else {
            status = (try? await availability.status(for: trimmed, to: dst)) ?? .supported
        }
        if status == .unsupported { throw TranslateError.unsupported(TranslateLanguages.name(of: target)) }
        bridge.cancelPending()
        return try await withCheckedThrowingContinuation { continuation in
            bridge.pending = (trimmed, continuation)
            let config = TranslationSession.Configuration(source: src, target: dst)
            if bridge.configuration?.source == config.source, bridge.configuration?.target == config.target {
                bridge.configuration?.invalidate()                 // 同样的语言再翻一次
            } else {
                bridge.configuration = config
            }
        }
    }

    func cancel() { bridge.cancelPending() }

    /// 这两种语言系统装没装（自检里只看不翻，不弹任何东西）
    static func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }
}
