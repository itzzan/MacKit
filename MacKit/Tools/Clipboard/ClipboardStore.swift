import AppKit

/// 剪贴板历史：排好序的列表 + 存盘。
/// 顺序：按最近复制的在前（台阶 14 起收藏的不再挤在最上面，单独有一栏"收藏"，按你排的顺序）。
/// 收藏的不受 200 条上限和"清空历史"影响。
/// 存在 ~/Library/Application Support/MacKit/Clipboard/：index.json 是列表，大的内容放在 blobs/ 里，
/// 收藏分组表放在 groups.json（台阶 23；另存一个文件，index.json 的格式不变，老历史照样读）
@MainActor
final class ClipboardStore {
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacKit/Clipboard", isDirectory: true)
    nonisolated static let inlineLimit = 32 * 1024

    private(set) var items: [ClipboardItem] = []
    /// 收藏分组，按建的先后（台阶 23）
    private(set) var groups: [ClipboardGroup] = []
    let directory: URL
    let limit: Int
    var onChange: (() -> Void)?

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var groupsURL: URL { directory.appendingPathComponent("groups.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    init(directory: URL = ClipboardStore.defaultDirectory, limit: Int = 200) {
        self.directory = directory
        self.limit = limit
    }

    // MARK: 读写磁盘

    func load() {
        if let data = try? Data(contentsOf: groupsURL),
           let saved = try? JSONDecoder().decode([ClipboardGroup].self, from: data) { groups = saved }
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = saved
        // 组没了（比如分组文件丢了）：那几条当"不分组"
        let ids = Set(groups.map(\.id))
        for i in items.indices where items[i].favoriteGroup.map({ !ids.contains($0) || !items[i].pinned }) == true {
            items[i].favoriteGroup = nil
        }
        Log.app.notice("clipboard: loaded \(saved.count) items, \(self.groups.count) groups")
    }

    private func saveGroups() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(groups).write(to: groupsURL, options: .atomic)
        } catch {
            Log.app.error("clipboard: groups save failed \(error.localizedDescription, privacy: .public)")
        }
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

    /// 新复制的内容。和已有的一样就把那条挪到最上面，返回这条
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

    /// 从历史里粘贴后：把它挪到最上面
    func touch(_ id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastCopied = now
        insert(item)
        save()
    }

    /// 图片里识别出来的字：存进这条的搜索内容（⌘3 里能搜到）
    func setRecognizedText(_ id: UUID, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .image else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].searchText = "图片 " + String(trimmed.prefix(10_000))
        save()
    }

    /// 收藏栏：按你排的顺序；老文件里的置顶没有顺序，按原来的先后
    var favorites: [ClipboardItem] {
        items.enumerated().filter { $0.element.pinned }
            .sorted { ($0.element.favoriteOrder ?? Int.max, $0.offset) < ($1.element.favoriteOrder ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// ⌘P：收藏 / 取消收藏。新收藏的排在收藏栏最前面
    func toggleFavorite(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].pinned {
            items[index].pinned = false
            items[index].favoriteName = nil
            items[index].favoriteOrder = nil
            items[index].favoriteGroup = nil                         // 取消收藏也就离开了它的组
        } else {
            let first = favorites.first?.favoriteOrder ?? 0
            items[index].pinned = true
            items[index].favoriteOrder = min(first, 0) - 1
            normalizeFavoriteOrder()
        }
        save()
    }

    /// ⌘R：给收藏起个名字（空的 = 不要名字）
    func setFavoriteName(_ id: UUID, _ name: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        items[index].favoriteName = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        if !items[index].pinned {                                    // 起名字 = 顺手收藏
            items[index].pinned = true
            items[index].favoriteOrder = (favorites.first?.favoriteOrder ?? 0) - 1
        }
        normalizeFavoriteOrder()
        save()
    }

    /// 在收藏栏里挪到第 to 个。group 不是 nil：在这个组里挪（只在这一组的几条之间换位置，"所有收藏"的顺序跟着变）
    func moveFavorite(_ id: UUID, to: Int, in group: UUID? = nil) {
        var list = favorites
        let slots = list.indices.filter { group == nil || list[$0].favoriteGroup == group }   // 这一组占着哪几个位置
        var sub = slots.map { list[$0] }
        guard let from = sub.firstIndex(where: { $0.id == id }) else { return }
        let item = sub.remove(at: from)
        sub.insert(item, at: min(max(to, 0), sub.count))
        for (slot, f) in zip(slots, sub) { list[slot] = f }
        for (order, f) in list.enumerated() {
            if let i = items.firstIndex(where: { $0.id == f.id }) { items[i].favoriteOrder = order }
        }
        save()
    }

    // MARK: 收藏分组（台阶 23）

    /// 收藏栏里的一组；group = nil 是"所有收藏"
    func favorites(in group: UUID?) -> [ClipboardItem] {
        guard let group else { return favorites }
        return favorites.filter { $0.favoriteGroup == group }
    }

    func group(_ id: UUID?) -> ClipboardGroup? { id.flatMap { id in groups.first { $0.id == id } } }

    /// 新建一个组（同名的已经有了就用那个）。名字空的不建
    @discardableResult
    func addGroup(_ name: String) -> ClipboardGroup? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty else { return nil }
        if let same = groups.first(where: { $0.name == trimmed }) { return same }
        let g = ClipboardGroup(id: UUID(), name: trimmed)
        groups.append(g)
        saveGroups()
        onChange?()
        return g
    }

    func renameGroup(_ id: UUID, _ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = trimmed
        saveGroups()
        onChange?()
    }

    /// 删掉一个组：里面的收藏不删，变成"不分组"
    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in items.indices where items[i].favoriteGroup == id { items[i].favoriteGroup = nil }
        saveGroups()
        save()
    }

    /// ⌘G：放进哪个组（nil = 不分组）。还没收藏的先收藏
    func setGroup(_ itemID: UUID, _ group: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if !items[index].pinned {
            items[index].pinned = true
            items[index].favoriteOrder = (favorites.first?.favoriteOrder ?? 0) - 1
            normalizeFavoriteOrder()
        }
        items[index].favoriteGroup = self.group(group)?.id
        save()
    }

    /// 顺序重新编成 0、1、2……（只在内存里，不单独存）
    private func normalizeFavoriteOrder() {
        for (order, f) in favorites.enumerated() {
            if let i = items.firstIndex(where: { $0.id == f.id }) { items[i].favoriteOrder = order }
        }
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBlobs(of: items.remove(at: index))
        save()
    }

    /// 清空历史，收藏的保留
    func clearUnpinned() {
        for item in items where !item.pinned { deleteBlobs(of: item) }
        items.removeAll { !$0.pinned }
        save()
    }

    var unpinnedCount: Int { items.filter { !$0.pinned }.count }

    private func insert(_ item: ClipboardItem) {
        items.insert(item, at: 0)
    }

    /// 超过上限时删最旧的（收藏的不算、不删）
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
