import XCTest
@testable import Cue

/// cue TUI 纯逻辑测试：按键流解析 / 选择钳制 / 删除-撤销
final class ClipTUITests: XCTestCase {

    // MARK: - KeyParser

    private func keys(from bytes: [UInt8]) -> [Key] {
        var parser = KeyParser()
        return bytes.compactMap { parser.feed($0) }
    }

    func testPlainCharacters() {
        XCTAssertEqual(keys(from: Array("ab ".utf8)), [.char("a"), .char("b"), .char(" ")])
    }

    func testUtf8ChineseCharacter() {
        let s = "剪"
        let out = keys(from: Array(s.utf8))
        XCTAssertEqual(out, [.char("剪")], "多字节 UTF-8 应合并为一个字符")
    }

    func testArrows() {
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x43]), [.right])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x44]), [.left])
    }

    func testPgUpPgDnHomeEnd() {
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x35, 0x7E]), [.pgUp])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x36, 0x7E]), [.pgDn])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x48]), [.home])
        XCTAssertEqual(keys(from: [0x1B, 0x5B, 0x46]), [.end])
        XCTAssertEqual(keys(from: [0x1B, 0x4F, 0x48]), [.home], "SS3 Home")
        XCTAssertEqual(keys(from: [0x1B, 0x4F, 0x46]), [.end], "SS3 End")
    }

    func testCtrlAndSpecial() {
        XCTAssertEqual(keys(from: [0x03]), [.ctrlC])
        XCTAssertEqual(keys(from: [0x0D]), [.enter])
        XCTAssertEqual(keys(from: [0x7F]), [.backspace])
        XCTAssertEqual(keys(from: [0x08]), [.backspace])
        var parser = KeyParser()
        XCTAssertNil(parser.feed(0x1B))
        XCTAssertEqual(parser.flushPending(), .esc)
        XCTAssertNil(parser.flushPending(), "冲掉后不再重复产出")
    }

    func testGarbageSequenceProducesNothing() {
        XCTAssertTrue(keys(from: [0x1B, 0x5B, 0x39, 0x39]).isEmpty, "未知 CSI 序列不产生按键")
    }

    // MARK: - 选择钳制

    func testClampSelection() {
        XCTAssertEqual(ClipTUI.clamped(selection: 5, count: 3), 2)
        XCTAssertEqual(ClipTUI.clamped(selection: -1, count: 3), 0)
        XCTAssertEqual(ClipTUI.clamped(selection: 0, count: 0), 0)
        XCTAssertEqual(ClipTUI.clamped(selection: 1, count: 5), 1)
    }

    // MARK: - 显示宽度

    func testCellWidth() {
        XCTAssertEqual(ClipTUI.cellWidth("abc"), 3)
        XCTAssertEqual(ClipTUI.cellWidth("中文"), 4)
        XCTAssertEqual(ClipTUI.cellWidth("a中b"), 4)
        XCTAssertEqual(ClipTUI.cellWidth("📌"), 2)
        XCTAssertEqual(ClipTUI.cellWidth(""), 0)
    }

    func testClipByDisplayWidth() {
        let long = String(repeating: "中", count: 50)
        let clipped = ClipTUI.clip(long, to: 11)
        XCTAssertTrue(ClipTUI.cellWidth(clipped) <= 11, "宽度 \(ClipTUI.cellWidth(clipped))")
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(ClipTUI.clip("短文本", to: 20), "短文本")
    }

    func testPadToDisplayWidth() {
        XCTAssertEqual(ClipTUI.cellWidth(ClipTUI.pad("中", to: 5)), 5)
        XCTAssertEqual(ClipTUI.pad("abc", to: 3), "abc")
        XCTAssertEqual(ClipTUI.cellWidth(ClipTUI.pad("abc", to: 7)), 7)
    }

    // MARK: - 删除-撤销

    func testTombstoneRestoresTextEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-tui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let e = store.add(text: "要删的内容", appName: "Arc", bundleId: "a")

        let stone = store.tombstone(id: e.id)
        XCTAssertNotNil(stone)
        XCTAssertEqual(stone?.text, "要删的内容")
        XCTAssertEqual(store.count, 0)

        XCTAssertTrue(store.restore(stone!))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.content(id: e.id), "要删的内容")
    }

    func testTombstoneRestoresImageBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-tui-img-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let e = store.addMetadata(type: .image, appName: "A", bundleId: "a", data: png)

        let stone = store.tombstone(id: e.id)
        XCTAssertEqual(stone?.image, png)
        XCTAssertTrue(store.restore(stone!))
        XCTAssertEqual(store.contentImage(id: e.id), png)
    }

    func testTombstoneMissingEntryReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-tui-miss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        XCTAssertNil(store.tombstone(id: "nonexistent"))
    }
}
