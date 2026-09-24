import Foundation

// MARK: - 数据模型

/// 历史记录类型：文本记录完整内容；图片/文件只记元数据
enum HistoryType: String, Codable {
    case text, image, file
}

/// 一条剪贴板历史记录（元数据；文本内容在独立的 <id>.txt 文件中）
struct HistoryEntry: Codable, Equatable {
    let id: String
    var createdAt: Date
    var updatedAt: Date
    var appName: String
    var bundleId: String
    var type: HistoryType
    var pinned: Bool
    var preview: String
}

enum HistoryStoreError: Error {
    case badFormat
}

// MARK: - 存储

/// 剪贴板历史存储：目录下每个条目一个 <id>.txt（文本内容），元数据集中在 index.json
/// 排序规则：置顶优先，其次按更新时间倒序
final class HistoryStore {
    private(set) var entries: [HistoryEntry]
    let directory: URL
    let maxEntries: Int

    private let indexURL: URL
    private let lock = NSLock()

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("cue/history", isDirectory: true)
    }

    init(directory: URL? = nil, maxEntries: Int = 500) {
        self.directory = directory ?? HistoryStore.defaultDirectory()
        self.maxEntries = maxEntries
        self.indexURL = self.directory.appendingPathComponent("index.json")
        self.entries = HistoryStore.loadIndex(from: self.indexURL)
    }

    // MARK: - 索引读写

    private static func loadIndex(from url: URL) -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let list = try decoder.decode([HistoryEntry].self, from: data)
            return Self.sorted(list)
        } catch {
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("bak"))
            return []
        }
    }

    private func saveIndex() {
        pruneGhostTextEntries()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            fputs("⚠️ 索引写入失败: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - 增

    @discardableResult
    func add(text: String, appName: String, bundleId: String) -> HistoryEntry {
        lock.lock(); defer { lock.unlock() }
        if let recent = mostRecent(), recent.type == .text,
           let recentContent = contentUnsafe(id: recent.id),
           recentContent == text {
            var updated = recent
            updated.updatedAt = Date()
            updated.appName = appName
            updated.bundleId = bundleId
            replace(updated)
            sortEntries()
            saveIndex()
            return updated
        }
        let entry = HistoryEntry(
            id: Self.makeID(),
            createdAt: Date(),
            updatedAt: Date(),
            appName: appName,
            bundleId: bundleId,
            type: .text,
            pinned: false,
            preview: Self.preview(of: text)
        )
        writeContent(entry.id, text)
        entries.append(entry)
        sortEntries()
        trim()
        saveIndex()
        return entry
    }

    @discardableResult
    func addMetadata(type: HistoryType, appName: String, bundleId: String, data: Data? = nil) -> HistoryEntry {
        lock.lock(); defer { lock.unlock() }
        let entry = HistoryEntry(
            id: Self.makeID(),
            createdAt: Date(),
            updatedAt: Date(),
            appName: appName,
            bundleId: bundleId,
            type: type,
            pinned: false,
            preview: type == .image ? "[图片]" : "[文件]"
        )
        entries.append(entry)
        if let data, type == .image {
            writeImage(entry.id, data)
        }
        sortEntries()
        trim()
        saveIndex()
        return entry
    }

    func contentImage(id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard get(id: id)?.type == .image else { return nil }
        return try? Data(contentsOf: imageURL(id))
    }

    func hasImageData(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return get(id: id)?.type == .image
            && FileManager.default.fileExists(atPath: imageURL(id).path)
    }

    // MARK: - 查

    var count: Int { entries.count }

    func get(id: String) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    func content(id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return contentUnsafe(id: id)
    }

    func list(search: String? = nil, limit: Int? = nil, pinnedOnly: Bool = false,
              app: String? = nil, type: HistoryType? = nil) -> [HistoryEntry] {
        var result = entries
        if pinnedOnly {
            result = result.filter { $0.pinned }
        }
        if let app = app, !app.isEmpty {
            let q = app.lowercased()
            result = result.filter { $0.appName.lowercased().contains(q) || $0.bundleId.lowercased().contains(q) }
        }
        if let type = type {
            result = result.filter { $0.type == type }
        }
        if let q = search, !q.isEmpty {
            result = result.filter { entry in
                if entry.preview.localizedCaseInsensitiveContains(q) { return true }
                if entry.type == .text, let content = content(id: entry.id) {
                    return content.localizedCaseInsensitiveContains(q)
                }
                return false
            }
        }
        if let n = limit, n > 0 {
            result = Array(result.prefix(n))
        }
        return result
    }

    func pruneOlderThan(days: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
        let doomed = entries.filter { !$0.pinned && $0.updatedAt < cutoff }
        guard !doomed.isEmpty else { return 0 }
        for e in doomed {
            if let idx = entries.firstIndex(where: { $0.id == e.id }) {
                entries.remove(at: idx)
            }
            removeEntryFiles(e.id)
        }
        saveIndex()
        return doomed.count
    }

    // MARK: - 导出 / 导入

    func export(to url: URL) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var items: [[String: Any]] = []
        for e in entries {
            var d: [String: Any] = [
                "id": e.id,
                "created_at": e.createdAt.timeIntervalSince1970,
                "updated_at": e.updatedAt.timeIntervalSince1970,
                "app_name": e.appName,
                "bundle_id": e.bundleId,
                "type": e.type.rawValue,
                "pinned": e.pinned,
                "preview": e.preview
            ]
            if e.type == .text, let content = contentUnsafe(id: e.id) {
                d["content"] = content
            }
            items.append(d)
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return entries.count
    }

    @discardableResult
    func `import`(from url: URL, replace: Bool) throws -> (imported: Int, skipped: Int) {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HistoryStoreError.badFormat
        }
        lock.lock(); defer { lock.unlock() }
        var imported = 0
        var skipped = 0
        for d in raw {
            guard let id = d["id"] as? String,
                  let typeRaw = d["type"] as? String,
                  let type = HistoryType(rawValue: typeRaw) else {
                skipped += 1
                continue
            }
            let createdAt = Date(timeIntervalSince1970: (d["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            let updatedAt = Date(timeIntervalSince1970: (d["updated_at"] as? NSNumber)?.doubleValue ?? createdAt.timeIntervalSince1970)
            let entry = HistoryEntry(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                appName: (d["app_name"] as? String) ?? "",
                bundleId: (d["bundle_id"] as? String) ?? "",
                type: type,
                pinned: (d["pinned"] as? Bool) ?? false,
                preview: (d["preview"] as? String) ?? Self.preview(of: (d["content"] as? String) ?? "")
            )

            if let idx = entries.firstIndex(where: { $0.id == id }) {
                if !replace {
                    skipped += 1
                    continue
                }
                entries[idx] = entry
            } else {
                entries.append(entry)
            }

            if type == .text, let content = d["content"] as? String {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? content.write(to: contentURL(id), atomically: true, encoding: .utf8)
            }
            imported += 1
        }
        entries.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
        saveIndex()
        return (imported, skipped)
    }

    // MARK: - 改

    @discardableResult
    func update(id: String, text: String) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = get(id: id), entry.type == .text else { return nil }
        entry.updatedAt = Date()
        entry.preview = Self.preview(of: text)
        replace(entry)
        writeContent(id, text)
        sortEntries()
        saveIndex()
        return entry
    }

    @discardableResult
    func setPinned(id: String, pinned: Bool) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = get(id: id) else { return nil }
        entry.pinned = pinned
        replace(entry)
        sortEntries()
        saveIndex()
        return entry
    }

    // MARK: - 删

    @discardableResult
    func delete(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: idx)
        removeEntryFiles(id)
        saveIndex()
        return true
    }

    // MARK: - 删除-撤销（TUI 用）

    struct Tombstone {
        let entry: HistoryEntry
        let text: String?
        let image: Data?
    }

    /// 删除并保留内容快照（供撤销恢复）
    func tombstone(id: String) -> Tombstone? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = get(id: id),
              let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var text: String?
        var image: Data?
        if entry.type == .text { text = try? String(contentsOf: contentURL(id), encoding: .utf8) }
        if entry.type == .image { image = try? Data(contentsOf: imageURL(id)) }
        entries.remove(at: idx)
        removeEntryFiles(id)
        saveIndex()
        return Tombstone(entry: entry, text: text, image: image)
    }

    /// 恢复一次删除（同 id 已存在则拒绝）
    func restore(_ stone: Tombstone) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.id == stone.entry.id }) else { return false }
        if stone.entry.type == .text, let text = stone.text {
            writeContent(stone.entry.id, text)
        }
        if stone.entry.type == .image, let image = stone.image {
            writeImage(stone.entry.id, image)
        }
        entries.append(stone.entry)
        sortEntries()
        saveIndex()
        return true
    }

    @discardableResult
    func clear() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = entries.count
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saveIndex()
        return n
    }

    // MARK: - 内部

    private func mostRecent() -> HistoryEntry? {
        entries.max { a, b in a.updatedAt < b.updatedAt }
    }

    private func replace(_ entry: HistoryEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
    }

    private func sortEntries() {
        entries.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    private func trim() {
        guard entries.count > maxEntries else { return }
        let unpinnedByNewest = entries.filter { !$0.pinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        let overflow = entries.count - maxEntries
        let toRemove = unpinnedByNewest.suffix(overflow)
        for e in toRemove {
            if let idx = entries.firstIndex(where: { $0.id == e.id }) {
                entries.remove(at: idx)
            }
            removeEntryFiles(e.id)
        }
    }

    private func pruneGhostTextEntries() {
        entries.removeAll { e in
            e.type == .text && !FileManager.default.fileExists(atPath: contentURL(e.id).path)
        }
    }

    private func contentURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).txt")
    }

    private func imageURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).img")
    }

    private func writeImage(_ id: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: imageURL(id), options: .atomic)
    }

    private func removeEntryFiles(_ id: String) {
        try? FileManager.default.removeItem(at: contentURL(id))
        try? FileManager.default.removeItem(at: imageURL(id))
    }

    private func contentUnsafe(id: String) -> String? {
        guard get(id: id)?.type == .text else { return nil }
        return try? String(contentsOf: contentURL(id), encoding: .utf8)
    }

    private func writeContent(_ id: String, _ text: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: contentURL(id), atomically: true, encoding: .utf8)
    }

    static func sorted(_ list: [HistoryEntry]) -> [HistoryEntry] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    static func makeID() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let ts = fmt.string(from: Date())
        let rand = String(format: "%06x", Int.random(in: 0...0xFFFFFF))
        return "\(ts)-\(rand)"
    }

    static func preview(of text: String, max: Int = 80) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max)) + "…"
    }
}

// MARK: - 统计

struct ClipStats {
    let total: Int
    let text: Int
    let image: Int
    let file: Int
    let pinned: Int
    let today: Int
    let last7Days: Int
    let last30Days: Int
    let topApps: [(name: String, count: Int)]

    static func compute(from entries: [HistoryEntry], now: Date = Date()) -> ClipStats {
        let text = entries.filter { $0.type == .text }.count
        let image = entries.filter { $0.type == .image }.count
        let file = entries.filter { $0.type == .file }.count
        let pinned = entries.filter { $0.pinned }.count
        let startOfToday = Calendar.current.startOfDay(for: now)
        let today = entries.filter { $0.updatedAt >= startOfToday }.count
        let last7 = entries.filter { $0.updatedAt >= now.addingTimeInterval(-7 * 86400) }.count
        let last30 = entries.filter { $0.updatedAt >= now.addingTimeInterval(-30 * 86400) }.count

        var counts: [String: Int] = [:]
        for e in entries {
            let name = e.appName.isEmpty ? "(未知)" : e.appName
            counts[name, default: 0] += 1
        }
        let top = counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }

        return ClipStats(total: entries.count, text: text, image: image, file: file,
                         pinned: pinned, today: today, last7Days: last7, last30Days: last30,
                         topApps: Array(top.prefix(10)))
    }
}
