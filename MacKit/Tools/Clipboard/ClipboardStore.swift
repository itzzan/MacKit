import AppKit

/// 剪贴板历史：排好序的列表 + 存盘。
/// 顺序：置顶的在最上面（最近置顶的在前），其余按最近复制的在前。
/// 存在 ~/Library/Application Support/MacKit/Clipboard/：index.json 是列表，大的内容放在 blobs/ 里
@MainActor
final class ClipboardStore {
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacKit/Clipboard", isDirectory: true)
    nonisolated static let inlineLimit = 32 * 1024

    private(set) var items: [ClipboardItem] = []
    let directory: URL
    let limit: Int
    var onChange: (() -> Void)?

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    init(directory: URL = ClipboardStore.defaultDirectory, limit: Int = 200) {
        self.directory = directory
        self.limit = limit
    }

    // MARK: 读写磁盘

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = saved
        Log.app.notice("clipboard: loaded \(saved.count) items")
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        } catch {
            Log.app.error("clipboard: save failed \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
    }

    /// 取出一种格式的内容
    func data(of entry: ClipboardEntry) -> Data? {
        if let inline = entry.inline { return inline }
        guard let blob = entry.blob else { return nil }
        return try? Data(contentsOf: blobDirectory.appendingPathComponent(blob))
    }

    private func deleteBlobs(of item: ClipboardItem) {
        for entry in item.pasteboardItems.flatMap({ $0 }) {
            if let blob = entry.blob { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(blob)) }
        }
    }

    // MARK: 增删改

    /// 新复制的内容。和已有的一样就把那条挪到最上面（置顶的留在原位），返回这条
    @discardableResult
    func add(_ s: ClipboardSnapshot, now: Date = Date()) -> ClipboardItem {
        if let index = items.firstIndex(where: { $0.fingerprint == s.fingerprint }) {
            var old = items.remove(at: index)
            deleteBlobs(of: old)
            old.pasteboardItems = storeEntries(s, id: old.id)        // 换成这次复制的格式（比如这次带了格式）
            old.lastCopied = now
            old.copyCount += 1
            old.sourceBundleID = s.sourceBundleID ?? old.sourceBundleID
            old.sourceName = s.sourceName ?? old.sourceName
            insert(old)
            trimAndSave()
            return old
        }
        let id = UUID()
        let item = ClipboardItem(id: id, pasteboardItems: storeEntries(s, id: id), kind: s.kind, title: s.title,
                                 searchText: s.searchText, imagePixelSize: s.imagePixelSize, fileCount: s.fileCount,
                                 fingerprint: s.fingerprint, sourceBundleID: s.sourceBundleID, sourceName: s.sourceName,
                                 firstCopied: now, lastCopied: now, copyCount: 1, pinned: false)
        insert(item)
        trimAndSave()
        return item
    }

    /// 从历史里粘贴后：把它挪到最上面（置顶的不动）
    func touch(_ id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastCopied = now
        insert(item)
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.pinned.toggle()
        if item.pinned {
            items.insert(item, at: 0)                                // 最近置顶的排最前
        } else {
            insert(item)
        }
        save()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBlobs(of: items.remove(at: index))
        save()
    }

    /// 清空历史，置顶的保留
    func clearUnpinned() {
        for item in items where !item.pinned { deleteBlobs(of: item) }
        items.removeAll { !$0.pinned }
        save()
    }

    var unpinnedCount: Int { items.filter { !$0.pinned }.count }

    private func insert(_ item: ClipboardItem) {
        if item.pinned {
            items.insert(item, at: 0)
        } else {
            let firstUnpinned = items.firstIndex { !$0.pinned } ?? items.endIndex
            items.insert(item, at: firstUnpinned)
        }
    }

    /// 超过上限时删最旧的（置顶的不算、不删）
    private func trimAndSave() {
        while unpinnedCount > limit, let last = items.lastIndex(where: { !$0.pinned }) {
            deleteBlobs(of: items.remove(at: last))
        }
        save()
    }

    private func storeEntries(_ s: ClipboardSnapshot, id: UUID) -> [[ClipboardEntry]] {
        try? FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        return s.pasteboardItems.enumerated().map { i, entries in
            entries.enumerated().map { j, e in
                if e.data.count <= Self.inlineLimit { return ClipboardEntry(type: e.type, inline: e.data, blob: nil) }
                let name = "\(id.uuidString)-\(i)-\(j).bin"
                do {
                    try e.data.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                    return ClipboardEntry(type: e.type, inline: nil, blob: name)
                } catch {
                    Log.app.error("clipboard: blob write failed \(error.localizedDescription, privacy: .public)")
                    return ClipboardEntry(type: e.type, inline: e.data, blob: nil)
                }
            }
        }
    }
}
