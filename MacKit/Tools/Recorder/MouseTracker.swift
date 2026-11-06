import AppKit

/// 录的时候记鼠标（台阶 21）：每秒 30 次看一眼鼠标在哪；点击用系统的全局鼠标事件（只看鼠标、不看键盘，不用新权限）。
/// 只在真的在录的时候记（clock 给出"视频里的第几秒"；暂停、还没开始时给 nil），所以时间和视频对得上
@MainActor
final class MouseTracker {
    /// 录的那块在屏幕上的位置（Cocoa 全局坐标）
    let frame: CGRect
    private let clock: () -> Double?
    private(set) var track = MouseTrack()
    private var timer: Timer?
    private var monitor: Any?

    init(frame: CGRect, clock: @escaping () -> Double?) {
        self.frame = frame
        self.clock = clock
    }

    func start() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(NSEvent.mouseLocation) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.click(at: NSEvent.mouseLocation) }
        }
    }

    /// 停下，交出记好的（duration = 视频一共多长）
    func stop(duration: Double) -> MouseTrack {
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        track.duration = duration
        return track
    }

    /// 记一下鼠标在哪（自检直接调）
    func sample(_ p: CGPoint) {
        guard let t = clock() else { return }
        let n = MouseTrack.normalize(p, in: frame)
        track.samples.append(.init(t: t, x: n.x, y: n.y))
    }

    /// 点了一下：只算点在录的那块里面的（点别的屏幕、点外面不推近）
    func click(at p: CGPoint) {
        guard let t = clock() else { return }
        sample(p)
        let n = MouseTrack.normalize(p, in: frame)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return }
        track.clicks.append(t)
    }
}

/// 鼠标记录存哪：~/Library/Application Support/MacKit/RecordTracks/<视频文件名>.json，只留最近 20 个。
/// 不放进影片文件夹，免得多出一堆看不懂的文件
enum MouseTrackStore {
    static var directory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MacKit/RecordTracks", isDirectory: true)
    }

    static func url(for video: URL, in dir: URL) -> URL { dir.appendingPathComponent(video.lastPathComponent + ".json") }

    static func save(_ track: MouseTrack, for video: URL, in dir: URL = directory, keep: Int = 20) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(track).write(to: url(for: video, in: dir), options: .atomic)
            prune(dir, keep: keep)
        } catch {
            Log.capture.error("mouse track save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load(for video: URL, in dir: URL = directory) -> MouseTrack? {
        guard let data = try? Data(contentsOf: url(for: video, in: dir)) else { return nil }
        return try? JSONDecoder().decode(MouseTrack.self, from: data)
    }

    /// 只留最近 keep 个
    private static func prune(_ dir: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "json" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
