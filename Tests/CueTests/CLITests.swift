import XCTest
@testable import Cue

final class CLITests: XCTestCase {

    // MARK: - 参数解析

    func testDefaultIsRecentList() {
        let opts = CLIParser.parse([])
        XCTAssertEqual(opts.action, .list)
        XCTAssertTrue(opts.recentOnly)
    }

    func testListSubcommandDisablesRecentOnly() {
        let opts = CLIParser.parse(["list"])
        XCTAssertEqual(opts.action, .list)
        XCTAssertFalse(opts.recentOnly)
    }

    func testShowParsesID() {
        let opts = CLIParser.parse(["show", "abc123"])
        XCTAssertEqual(opts.action, .show)
        XCTAssertEqual(opts.id, "abc123")
    }

    func testAddParsesText() {
        let opts = CLIParser.parse(["add", "hello world"])
        XCTAssertEqual(opts.action, .add)
        XCTAssertEqual(opts.text, "hello world")
    }

    func testEditParsesIDAndText() {
        let opts = CLIParser.parse(["edit", "id1", "new text"])
        XCTAssertEqual(opts.action, .edit)
        XCTAssertEqual(opts.id, "id1")
        XCTAssertEqual(opts.text, "new text")
    }

    func testFlagsAndOptions() {
        let opts = CLIParser.parse(["list", "--search", "foo", "--limit", "10", "--json", "--pinned"])
        XCTAssertEqual(opts.search, "foo")
        XCTAssertEqual(opts.limit, 10)
        XCTAssertTrue(opts.json)
        XCTAssertTrue(opts.pinnedOnly)
    }

    func testEqualsStyleOptions() {
        let opts = CLIParser.parse(["list", "--search=bar", "--limit=5", "--type=text"])
        XCTAssertEqual(opts.search, "bar")
        XCTAssertEqual(opts.limit, 5)
        XCTAssertEqual(opts.typeFilter, "text")
    }

    func testRecordOptions() {
        let opts = CLIParser.parse(["record", "--interval", "0.5", "--max", "100", "--ttl", "7", "--json"])
        XCTAssertEqual(opts.action, .record)
        XCTAssertEqual(opts.interval, 0.5)
        XCTAssertEqual(opts.max, 100)
        XCTAssertEqual(opts.ttlDays, 7)
        XCTAssertTrue(opts.json)
    }

    func testDaemonFlags() {
        let opts = CLIParser.parse(["record", "--daemon"])
        XCTAssertEqual(opts.action, .record)
        XCTAssertTrue(opts.daemon)
        XCTAssertFalse(opts.daemonChild)

        let child = CLIParser.parse(["record", "--daemon-child"])
        XCTAssertTrue(child.daemonChild)
    }

    func testExtraPositionalsProduceWarning() {
        let opts = CLIParser.parse(["list", "extra", "junk"])
        XCTAssertEqual(opts.action, .list)
        XCTAssertEqual(opts.warnings.count, 1)
    }

    func testBootstrapsAsTopLevel() {
        // `cue list` 与 `cue clip list` 等价
        let a = CLIParser.parse(["list"])
        let b = CLIParser.parse(["list"])
        XCTAssertEqual(a.action, b.action)
        XCTAssertEqual(a.recentOnly, b.recentOnly)
    }

    // MARK: - 守护进程 plist 生成

    func testLaunchAgentPlistContainsBinaryAndLabel() {
        let plist = ClipDaemon.launchAgentPlist(binaryPath: "/usr/local/bin/cue")
        XCTAssertTrue(plist.contains("com.cue.clipd"))
        XCTAssertTrue(plist.contains("/usr/local/bin/cue"))
        XCTAssertTrue(plist.contains("record"))
        XCTAssertTrue(plist.contains("--daemon-child"))
        XCTAssertTrue(plist.contains("KeepAlive"))
    }

    func testRecordChildArgsPassthrough() {
        let args = ClipDaemon.recordChildArgs(interval: 0.5, max: 200, ttl: 30)
        XCTAssertEqual(args, ["record", "--daemon-child", "--interval", "0.5", "--max", "200", "--ttl", "30"])

        let noTTL = ClipDaemon.recordChildArgs(interval: 0.3, max: 500, ttl: 0)
        XCTAssertFalse(noTTL.contains("--ttl"))
    }

    // MARK: - 断更提醒

    func testStalenessNote() {
        let now = Date()
        let recent = now.addingTimeInterval(-3600)  // 1 小时前
        XCTAssertNil(ClipCommand.stalenessNote(lastUpdate: recent, now: now))

        let stale = now.addingTimeInterval(-48 * 3600)  // 2 天前
        XCTAssertNotNil(ClipCommand.stalenessNote(lastUpdate: stale, now: now))

        XCTAssertNil(ClipCommand.stalenessNote(lastUpdate: nil, now: now))
    }
}
