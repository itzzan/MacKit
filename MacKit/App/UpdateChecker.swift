import AppKit

/// 检查更新（台阶 17，第二版方案拍板：只在你点的时候问 GitHub，平时照旧不联网）。
/// 只读 GitHub 上"最新发布"的版本号、更新说明、下载页地址，不发任何你的东西，不自动下载
@MainActor
final class UpdateChecker {
    enum Result: Equatable {
        case upToDate(String)                                   // 已是最新（现在的版本号）
        case newer(version: String, notes: String, page: URL)   // 有新版
        case failed(String)                                     // 连不上 / 看不懂
    }

    typealias Fetch = (URL) async throws -> Data
    static let latestURL = URL(string: "https://api.github.com/repos/itzzan/MacKit/releases/latest")!
    let fetch: Fetch

    /// fetch：自检里换成假的，不真的联网
    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.network
    }

    func check(current: String = AppInfo.version) async -> Result {
        do {
            let data = try await fetch(Self.latestURL)
            return Self.parse(data, current: current)
        } catch {
            Log.app.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed("连不上 GitHub，等会儿再试")
        }
    }

    /// GitHub 回的那段 JSON → 结论
    static func parse(_ data: Data, current: String) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return .failed("GitHub 的回答看不懂，等会儿再试") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard AppVersion.isNewer(version, than: current) else { return .upToDate(current) }
        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppLinks.releases
        return .newer(version: version, notes: notes, page: page)
    }

    /// 真的去问：10 秒连不上就算失败；不带 cookie、不存缓存
    static func network(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacKit/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return data
    }

    /// 一行话说结果
    static func summary(_ r: Result) -> String {
        switch r {
        case .upToDate(let v): "已是最新版本 \(v)"
        case .newer(let v, _, _): "有新版本 \(v)（你现在是 \(AppInfo.version)）"
        case .failed(let why): why
        }
    }
}
