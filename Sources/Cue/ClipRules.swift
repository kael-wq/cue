import Foundation

/// 入库规则：忽略来源（App 名/包名）与敏感词（文本内容）
final class ClipRules {
    private let ignoreURL: URL
    private let sensitiveURL: URL

    var ignoreList: [String] { load(ignoreURL) }
    var sensitiveList: [String] { load(sensitiveURL) }

    init(directory: URL? = nil) {
        let dir = directory ?? HistoryStore.defaultDirectory()
        self.ignoreURL = dir.appendingPathComponent("ignore.txt")
        self.sensitiveURL = dir.appendingPathComponent("sensitive.txt")
    }

    func shouldIgnore(app: String, bundleId: String) -> Bool {
        let list = ignoreList
        guard !list.isEmpty else { return false }
        let target = "\(app)\n\(bundleId)".lowercased()
        return list.contains { !$0.isEmpty && target.contains($0.lowercased()) }
    }

    func containsSensitive(text: String) -> Bool {
        let list = sensitiveList
        guard !list.isEmpty else { return false }
        let lower = text.lowercased()
        return list.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    func addIgnore(_ word: String) {
        var list = ignoreList
        if !list.contains(word) { list.append(word) }
        save(list, to: ignoreURL)
    }

    func addSensitive(_ word: String) {
        var list = sensitiveList
        if !list.contains(word) { list.append(word) }
        save(list, to: sensitiveURL)
    }

    func clearIgnore() {
        save([], to: ignoreURL)
    }

    func clearSensitive() {
        save([], to: sensitiveURL)
    }

    private func load(_ url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return data.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func save(_ list: [String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? list.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
