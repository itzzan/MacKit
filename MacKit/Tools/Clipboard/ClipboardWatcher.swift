import AppKit

/// 每半秒看一眼剪贴板的"变更编号"，变了才去读内容（Maccy 也这么做）。只读不写
@MainActor
final class ClipboardWatcher {
    let pasteboard: NSPasteboard
    var isPaused: () -> Bool = { false }
    var onSnapshot: ((ClipboardSnapshot) -> Void)?
    private var lastChange: Int
    private var timer: Timer?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        lastChange = pasteboard.changeCount          // 启动前就在剪贴板里的不算新复制的
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)       // 拖动、菜单打开时也照常检查
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if isPaused() { return }
        switch ClipboardReader.read(pasteboard) {
        case .success(let snapshot):
            onSnapshot?(snapshot)
        case .failure(let why):
            if why == .ignored { Log.app.notice("clipboard: skipped concealed/transient content") }
            if why == .tooBig { Log.app.notice("clipboard: skipped content over 20 MB") }
        }
    }
}
