import XCTest
@testable import Cue

final class HistoryStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(maxEntries: Int = 500) -> HistoryStore {
        HistoryStore(directory: dir, maxEntries: maxEntries)
    }

    // MARK: - 增

    func testAddWritesContentAndIndex() {
        let store = makeStore()
        let entry = store.add(text: "hello world", appName: "Safari", bundleId: "com.apple.Safari")

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.get(id: entry.id)?.preview, "hello world")
        XCTAssertEqual(store.content(id: entry.id), "hello world")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(entry.id).txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path))
    }

    func testDaemonDoesNotResurrectClearedEntries() {
        let daemon = makeStore()
        let _ = daemon.add(text: "old one", appName: "A", bundleId: "a")
        let _ = daemon.add(text: "old two", appName: "A", bundleId: "a")
        XCTAssertEqual(daemon.count, 2)

        let clearer = HistoryStore(directory: dir)
        XCTAssertEqual(clearer.clear(), 2)

        let fresh = daemon.add(text: "new after clear", appName: "B", bundleId: "b")
        XCTAssertEqual(fresh.preview, "new after clear")

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.count, 1, "旧条目不得在 clear 后复活")
        XCTAssertEqual(reloaded.entries.first?.id, fresh.id)
    }

    func testAddPreviewTruncatesMultiline() {
        let store = makeStore()
        let long = String(repeating: "a", count: 100)
        let entry = store.add(text: "line1\nline2\(long)", appName: "X", bundleId: "x")

        let preview = store.get(id: entry.id)!.preview
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertTrue(preview.count <= 81)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testAdjacentDedupUpdatesTimestamp() {
        let store = makeStore()
        let first = store.add(text: "same", appName: "A", bundleId: "a")
        Thread.sleep(forTimeInterval: 0.01)
        let second = store.add(text: "same", appName: "B", bundleId: "b")

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.get(id: first.id)?.appName, "B")
        XCTAssertGreaterThan(store.get(id: first.id)!.updatedAt, first.updatedAt)
    }

    func testSameTextNotAdjacentKeepsBoth() {
        let store = makeStore()
        store.add(text: "a", appName: "A", bundleId: "a")
        store.add(text: "b", appName: "B", bundleId: "b")
        store.add(text: "a", appName: "C", bundleId: "c")

        XCTAssertEqual(store.count, 3)
    }

    func testMaxCapTrimsOldestUnpinned() {
        let store = makeStore(maxEntries: 3)
        let e1 = store.add(text: "1", appName: "A", bundleId: "a")
        let e2 = store.add(text: "2", appName: "A", bundleId: "a")
        let e3 = store.add(text: "3", appName: "A", bundleId: "a")
        let e4 = store.add(text: "4", appName: "A", bundleId: "a")

        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.get(id: e1.id))
        XCTAssertNotNil(store.get(id: e2.id))
        XCTAssertNotNil(store.get(id: e3.id))
        XCTAssertNotNil(store.get(id: e4.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(e1.id).txt").path))
    }

    func testPinnedSurvivesTrim() {
        let store = makeStore(maxEntries: 3)
        let p1 = store.add(text: "keep", appName: "A", bundleId: "a")
        _ = store.setPinned(id: p1.id, pinned: true)
        store.add(text: "2", appName: "A", bundleId: "a")
        store.add(text: "3", appName: "A", bundleId: "a")
        store.add(text: "4", appName: "A", bundleId: "a")

        XCTAssertEqual(store.count, 3)
        XCTAssertNotNil(store.get(id: p1.id))
    }

    func testAddMetadataForImage() {
        let store = makeStore()
        let entry = store.addMetadata(type: .image, appName: "Preview", bundleId: "com.apple.Preview")

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(entry.type, .image)
        XCTAssertEqual(store.get(id: entry.id)?.preview, "[图片]")
        XCTAssertNil(store.content(id: entry.id))
    }

    // MARK: - 查

    func testListSortsPinnedFirstThenTimeDesc() {
        let store = makeStore()
        store.add(text: "first", appName: "A", bundleId: "a")
        let second = store.add(text: "second", appName: "B", bundleId: "b")
        store.add(text: "third", appName: "C", bundleId: "c")
        _ = store.setPinned(id: second.id, pinned: true)

        let list = store.list()
        XCTAssertEqual(list.first?.id, second.id)
        XCTAssertEqual(list.map(\.preview), ["second", "third", "first"])
    }

    func testSearchFiltersByPreview() {
        let store = makeStore()
        store.add(text: "hello world", appName: "A", bundleId: "a")
        store.add(text: "goodbye moon", appName: "B", bundleId: "b")

        XCTAssertEqual(store.list(search: "hello").count, 1)
        XCTAssertEqual(store.list(search: "MOON").count, 1)
        XCTAssertEqual(store.list(search: "xyz").count, 0)
    }

    func testLimitAndPinnedOnly() {
        let store = makeStore()
        store.add(text: "1", appName: "A", bundleId: "a")
        store.add(text: "2", appName: "B", bundleId: "b")
        store.add(text: "3", appName: "C", bundleId: "c")
        let e2 = store.list().first(where: { $0.preview == "2" })!
        _ = store.setPinned(id: e2.id, pinned: true)

        XCTAssertEqual(store.list(limit: 2).count, 2)
        XCTAssertEqual(store.list(pinnedOnly: true).count, 1)
    }

    // MARK: - 改

    func testUpdateChangesContentAndTimestamp() {
        let store = makeStore()
        let entry = store.add(text: "old", appName: "A", bundleId: "a")
        Thread.sleep(forTimeInterval: 0.01)

        guard let updated = store.update(id: entry.id, text: "new content") else {
            return XCTFail("update 返回 nil")
        }
        XCTAssertEqual(store.content(id: entry.id), "new content")
        XCTAssertEqual(updated.preview, "new content")
        XCTAssertGreaterThan(updated.updatedAt, entry.updatedAt)
    }

    func testUpdateMissingEntryReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.update(id: "nope", text: "x"))
    }

    func testPinUnpinRoundTrip() {
        let store = makeStore()
        let entry = store.add(text: "x", appName: "A", bundleId: "a")

        _ = store.setPinned(id: entry.id, pinned: true)
        XCTAssertTrue(store.get(id: entry.id)!.pinned)

        _ = store.setPinned(id: entry.id, pinned: false)
        XCTAssertFalse(store.get(id: entry.id)!.pinned)
    }

    // MARK: - 删

    func testDeleteRemovesEntryAndFile() {
        let store = makeStore()
        let entry = store.add(text: "bye", appName: "A", bundleId: "a")

        XCTAssertTrue(store.delete(id: entry.id))
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(entry.id).txt").path))

        XCTAssertFalse(store.delete(id: entry.id))
    }

    func testClearRemovesEverything() {
        let store = makeStore()
        store.add(text: "1", appName: "A", bundleId: "a")
        store.add(text: "2", appName: "A", bundleId: "a")

        XCTAssertEqual(store.clear(), 2)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - 持久化

    func testPersistenceAcrossInstances() {
        let first = makeStore()
        let entry = first.add(text: "persist me", appName: "A", bundleId: "a")
        _ = first.setPinned(id: entry.id, pinned: true)

        let second = makeStore()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.get(id: entry.id)?.preview, "persist me")
        XCTAssertTrue(second.get(id: entry.id)!.pinned)
        XCTAssertEqual(second.content(id: entry.id), "persist me")
    }

    func testCorruptIndexRecoversWithBackup() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("not json at all".utf8).write(to: dir.appendingPathComponent("index.json"))

        let store = makeStore()
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json.bak").path))
    }

    func testMissingDirectoryStartsEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.get(id: "anything"))
    }

    // MARK: - 全文搜索

    func testFullTextSearchMatchesBeyondPreview() {
        let store = makeStore()
        let long = "a" + String(repeating: "x", count: 120) + "SEARCH-KEY" + String(repeating: "y", count: 50)
        store.add(text: long, appName: "A", bundleId: "a")
        store.add(text: "plain hello", appName: "A", bundleId: "a")

        let hits = store.list(search: "SEARCH-KEY")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].preview.hasPrefix("a"))
    }

    func testFullTextSearchCaseInsensitive() {
        let store = makeStore()
        store.add(text: "申请单号 AbC12345 请查收", appName: "A", bundleId: "a")
        let hits = store.list(search: "abc12345")
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - 导出 / 导入

    func testExportImportRoundTrip() {
        let src = makeStore()
        let e1 = src.add(text: "hello world 内容", appName: "Safari", bundleId: "com.apple.Safari")
        _ = src.setPinned(id: e1.id, pinned: true)
        let e2 = src.addMetadata(type: .image, appName: "WeChat", bundleId: "com.tencent.xinWeChat")
        Thread.sleep(forTimeInterval: 0.01)
        let e3 = src.add(text: String(repeating: "long ", count: 200), appName: "VS Code", bundleId: "com.microsoft.VSCode")

        let exportURL = dir.appendingPathComponent("export.json")
        let n = try! src.export(to: exportURL)
        XCTAssertEqual(n, 3)

        let dstDir = dir.appendingPathComponent("restored", isDirectory: true)
        let dst = HistoryStore(directory: dstDir)
        let (imported, skipped) = try! dst.import(from: exportURL, replace: false)
        XCTAssertEqual(imported, 3)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(dst.count, 3)

        XCTAssertEqual(dst.content(id: e1.id), "hello world 内容")
        XCTAssertTrue(dst.get(id: e1.id)!.pinned)
        XCTAssertEqual(dst.get(id: e2.id)?.type, .image)
        XCTAssertNil(dst.content(id: e2.id))
        XCTAssertEqual(dst.content(id: e3.id), String(repeating: "long ", count: 200))
        XCTAssertEqual(dst.get(id: e1.id)?.createdAt.timeIntervalSince1970,
                       src.get(id: e1.id)?.createdAt.timeIntervalSince1970)
        XCTAssertEqual(dst.get(id: e1.id)?.updatedAt.timeIntervalSince1970,
                       src.get(id: e1.id)?.updatedAt.timeIntervalSince1970)
    }

    func testImportSkipsExistingUnlessReplace() {
        let src = makeStore()
        src.add(text: "original", appName: "A", bundleId: "a")
        let exportURL = dir.appendingPathComponent("export2.json")
        _ = try! src.export(to: exportURL)

        let dst = makeStore()
        dst.add(text: "different local content", appName: "B", bundleId: "b")
        _ = try! dst.import(from: exportURL, replace: false)
        XCTAssertEqual(dst.count, 2)
        let (_, skipped2) = try! dst.import(from: exportURL, replace: false)
        XCTAssertEqual(skipped2, 1)
        XCTAssertEqual(dst.count, 2)
        XCTAssertTrue(dst.entries.contains { $0.preview == "original" })
        XCTAssertTrue(dst.entries.contains { $0.preview == "different local content" })
    }

    func testImportMissingFileThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try store.import(from: dir.appendingPathComponent("nope.json"), replace: false))
    }

    // MARK: - 来源/类型过滤

    func testListFiltersByAppName() {
        let store = makeStore()
        store.add(text: "a", appName: "Safari", bundleId: "com.apple.Safari")
        store.add(text: "b", appName: "微信", bundleId: "com.tencent.xinWeChat")
        store.add(text: "c", appName: "Arc", bundleId: "company.thebrowser.Browser")
        XCTAssertEqual(store.list(app: "safari").count, 1)
        XCTAssertEqual(store.list(app: "微信").count, 1)
        XCTAssertEqual(store.list(app: "S").count, 2)
        XCTAssertEqual(store.list(app: "不存在").count, 0)
    }

    func testListFiltersByType() {
        let store = makeStore()
        store.add(text: "t", appName: "A", bundleId: "a")
        store.addMetadata(type: .image, appName: "A", bundleId: "a")
        store.addMetadata(type: .file, appName: "A", bundleId: "a")
        XCTAssertEqual(store.list(type: .text).count, 1)
        XCTAssertEqual(store.list(type: .image).count, 1)
        XCTAssertEqual(store.list(type: .file).count, 1)
        XCTAssertEqual(store.list(app: "A", type: .text).count, 1)
    }

    // MARK: - TTL 过期清理

    func testPruneOlderThanRemovesExpiredKeepsPinned() {
        let store = makeStore()
        store.add(text: "recent", appName: "A", bundleId: "a")
        let oldID = "20260801-000000-old1"
        let importURL = dir.appendingPathComponent("old.json")
        let oldJSON: [[String: Any]] = [
            ["id": oldID, "type": "text", "content": "old content", "preview": "old",
             "app_name": "B", "bundle_id": "b",
             "created_at": 1754000000.0, "updated_at": 1754000000.0, "pinned": false]
        ]
        try! JSONSerialization.data(withJSONObject: oldJSON).write(to: importURL)
        _ = try! store.import(from: importURL, replace: false)
        XCTAssertEqual(store.count, 2)

        let removed = store.pruneOlderThan(days: 30)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertFalse(store.entries.contains { $0.id == oldID })
    }

    func testPruneKeepsPinnedEvenWhenOld() {
        let store = makeStore()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let importURL = dir.appendingPathComponent("oldpinned.json")
        let oldJSON: [[String: Any]] = [
            ["id": "20260701-000000-pinned", "type": "text", "content": "keep", "preview": "keep",
             "app_name": "B", "bundle_id": "b",
             "created_at": 1751000000.0, "updated_at": 1751000000.0, "pinned": true]
        ]
        try! JSONSerialization.data(withJSONObject: oldJSON).write(to: importURL)
        _ = try! store.import(from: importURL, replace: false)
        XCTAssertEqual(store.pruneOlderThan(days: 30), 0)
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - 统计

    func testStatsComputesCounts() {
        let store = makeStore()
        let t1 = store.add(text: "x", appName: "Safari", bundleId: "a")
        store.add(text: "y", appName: "Safari", bundleId: "a")
        store.add(text: "z", appName: "微信", bundleId: "b")
        store.add(text: "w", appName: "微信", bundleId: "b")
        store.addMetadata(type: .image, appName: "微信", bundleId: "b")
        _ = store.setPinned(id: t1.id, pinned: true)

        let s = ClipStats.compute(from: store.entries, now: Date())
        XCTAssertEqual(s.total, 5)
        XCTAssertEqual(s.text, 4)
        XCTAssertEqual(s.image, 1)
        XCTAssertEqual(s.pinned, 1)
        XCTAssertEqual(s.topApps.first?.name, "微信")
        XCTAssertEqual(s.topApps.first?.count, 3)
        XCTAssertEqual(s.today, 5)
        XCTAssertEqual(s.last7Days, 5)
    }

    func testStatsTopAppsTieBreaksAlphabetically() {
        let store = makeStore()
        store.add(text: "1", appName: "Bapp", bundleId: "b")
        store.add(text: "2", appName: "Aapp", bundleId: "a")
        let s = ClipStats.compute(from: store.entries, now: Date())
        XCTAssertEqual(s.topApps.count, 2)
        XCTAssertEqual(s.topApps.map { $0.count }, [1, 1])
    }

    // MARK: - 图片记录

    func testAddMetadataWithImageDataPersists() {
        let store = makeStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let entry = store.addMetadata(type: .image, appName: "微信", bundleId: "b", data: png)
        XCTAssertEqual(entry.type, .image)
        XCTAssertEqual(store.contentImage(id: entry.id), png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(entry.id).img").path))

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.contentImage(id: entry.id), png)
    }

    func testDeleteRemovesImageFileToo() {
        let store = makeStore()
        let entry = store.addMetadata(type: .image, appName: "A", bundleId: "a", data: Data([1, 2, 3]))
        let imgPath = dir.appendingPathComponent("\(entry.id).img").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: imgPath))
        _ = store.delete(id: entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imgPath))
    }

    func testPruneRemovesImageFile() {
        let store = makeStore()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let importURL = dir.appendingPathComponent("oldimg.json")
        let oldJSON: [[String: Any]] = [
            ["id": "20260701-000000-img", "type": "image", "preview": "[图片]",
             "app_name": "B", "bundle_id": "b",
             "created_at": 1751000000.0, "updated_at": 1751000000.0, "pinned": false]
        ]
        try! JSONSerialization.data(withJSONObject: oldJSON).write(to: importURL)
        _ = try! store.import(from: importURL, replace: false)
        XCTAssertEqual(store.pruneOlderThan(days: 30), 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testImageWithoutDataStillLoadsAsMetadata() {
        let store = makeStore()
        let entry = store.addMetadata(type: .image, appName: "A", bundleId: "a")
        XCTAssertNil(store.contentImage(id: entry.id))
        XCTAssertEqual(store.list(type: .image).count, 1)
    }
}
