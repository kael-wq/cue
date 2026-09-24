// 轻量无依赖自测（不需要 XCTest / 完整 Xcode）
// 编译并运行：
//   swiftc Sources/Cue/HistoryStore.swift Sources/Cue/CLI.swift Sources/Cue/ClipDaemon.swift Sources/Cue/ClipRules.swift Scripts/selftest.swift -o /tmp/selftest && /tmp/selftest
//
// 覆盖 HistoryStore / ClipStats / CLIParser / ClipDaemon.plist / ClipRules 的核心逻辑。

import Foundation

var failures = 0
var passes = 0

func check(_ cond: Bool, _ msg: String) {
    if cond { passes += 1 }
    else { failures += 1; print("  ✗ \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    check(a == b, "\(msg) (got \(a), want \(b))")
}

// MARK: - 临时目录

func tmpDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cue-selftest-\(UUID().uuidString)")
}

// MARK: - HistoryStore

func testHistoryStore() {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 增
    let store = HistoryStore(directory: dir)
    let e = store.add(text: "hello world", appName: "Safari", bundleId: "com.apple.Safari")
    eq(store.count, 1, "add 后 count == 1")
    eq(store.content(id: e.id), "hello world", "content 正确")
    eq(e.preview, "hello world", "preview 正确")

    // 相邻去重
    let e2 = store.add(text: "hello world", appName: "Chrome", bundleId: "x")
    eq(store.count, 1, "相邻相同内容去重")
    eq(e2.id, e.id, "去重后同 id")

    // 非相邻不合并
    store.add(text: "second", appName: "A", bundleId: "a")
    store.add(text: "hello world", appName: "B", bundleId: "b")
    eq(store.count, 3, "非相邻相同内容保留")

    // 预览截断 + 多行合并
    let long = "line1\nline2" + String(repeating: "a", count: 100)
    let el = store.add(text: long, appName: "X", bundleId: "x")
    let pv = store.get(id: el.id)!.preview
    check(!pv.contains("\n"), "预览无换行")
    check(pv.count <= 81 && pv.hasSuffix("…"), "预览截断到 80+…")

    // 置顶排序
    _ = store.setPinned(id: e.id, pinned: true)
    let list = store.list()
    eq(list.first?.id, e.id, "置顶排最前")

    // 搜索
    eq(store.list(search: "SECOND").count, 1, "搜索大小写不敏感")
    eq(store.list(search: "zzz").count, 0, "无命中")

    // 全文搜索（预览之外）
    let needle = "UNIQUE-KEY-123"
    store.add(text: String(repeating: "a", count: 120) + needle, appName: "A", bundleId: "a")
    eq(store.list(search: needle).count, 1, "全文搜索命中预览之外内容")

    // 过滤（去重时 e 的 appName 已更新为 Chrome）
    eq(store.list(app: "chrome").count, 1, "按来源过滤（大小写不敏感）")
    eq(store.list(type: .text).count, store.count, "全是文本")

    // 图片元数据
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let img = store.addMetadata(type: .image, appName: "微信", bundleId: "b", data: png)
    eq(img.type, .image, "图片类型")
    eq(store.contentImage(id: img.id), png, "图片字节持久化")

    // 删除 + 撤销
    let stone = store.tombstone(id: img.id)
    check(stone != nil, "tombstone 非空")
    check(store.get(id: img.id) == nil, "删除后查不到")
    check(store.restore(stone!), "撤销成功")
    eq(store.contentImage(id: img.id), png, "撤销后图片字节恢复")

    // 删除
    check(store.delete(id: img.id), "删除图片")
    check(!store.entries.contains { $0.id == img.id }, "图片已删除")

    // TTL 清理
    let store2 = HistoryStore(directory: dir)
    let oldID = "20260801-000000-old"
    let importURL = dir.appendingPathComponent("old.json")
    let oldJSON: [[String: Any]] = [
        ["id": oldID, "type": "text", "content": "old", "preview": "old",
         "app_name": "B", "bundle_id": "b",
         "created_at": 1754000000.0, "updated_at": 1754000000.0, "pinned": false]
    ]
    try! JSONSerialization.data(withJSONObject: oldJSON).write(to: importURL)
    let before = store2.count
    _ = try! store2.import(from: importURL, replace: false)
    eq(store2.count, before + 1, "导入成功")
    let removed = store2.pruneOlderThan(days: 30)
    eq(removed, 1, "清理 30 天前旧条目")
    check(!store2.entries.contains { $0.id == oldID }, "旧条目已移除")

    // 统计
    let s = ClipStats.compute(from: store2.entries)
    check(s.total == store2.count, "统计 total 一致")

    // 导出/导入
    let exportURL = dir.appendingPathComponent("exp.json")
    let n = try! store2.export(to: exportURL)
    eq(n, store2.count, "导出条数")
    let dst = HistoryStore(directory: dir.appendingPathComponent("dst"))
    let (imp, skp) = try! dst.import(from: exportURL, replace: false)
    eq(imp, n, "导入条数")
    eq(skp, 0, "跳过 0")
    eq(dst.count, n, "导入后 count")

    print("  HistoryStore: OK")
}

// MARK: - CLIParser

func testCLIParser() {
    var o = CLIParser.parse([])
    eq(o.action, .list, "默认 action")
    check(o.recentOnly, "默认 recentOnly")

    o = CLIParser.parse(["list"])
    eq(o.action, .list, "list action")
    check(!o.recentOnly, "list 子命令关闭 recentOnly")

    o = CLIParser.parse(["show", "abc"])
    eq(o.action, .show, "show action")
    eq(o.id, "abc", "show id")

    o = CLIParser.parse(["add", "hello"])
    eq(o.action, .add, "add action")
    eq(o.text, "hello", "add text")

    o = CLIParser.parse(["edit", "i1", "new"])
    eq(o.action, .edit, "edit action")
    eq(o.id, "i1", "edit id")
    eq(o.text, "new", "edit text")

    o = CLIParser.parse(["list", "--search", "foo", "--limit", "10", "--json", "--pinned"])
    eq(o.search, "foo", "search")
    eq(o.limit, 10, "limit")
    check(o.json, "json")
    check(o.pinnedOnly, "pinnedOnly")

    o = CLIParser.parse(["list", "--search=bar", "--type=text"])
    eq(o.search, "bar", "search=")
    eq(o.typeFilter, "text", "type=")

    o = CLIParser.parse(["record", "--interval", "0.5", "--max", "100", "--ttl", "7"])
    eq(o.interval, 0.5, "interval")
    eq(o.max, 100, "max")
    eq(o.ttlDays, 7, "ttl")

    o = CLIParser.parse(["record", "--daemon"])
    check(o.daemon, "daemon")
    check(!o.daemonChild, "非 child")

    o = CLIParser.parse(["record", "--daemon-child"])
    check(o.daemonChild, "daemon-child")

    o = CLIParser.parse(["list", "extra", "junk"])
    eq(o.warnings.count, 1, "多余参数告警")

    print("  CLIParser: OK")
}

// MARK: - ClipDaemon plist

func testClipDaemon() {
    let p = ClipDaemon.launchAgentPlist(binaryPath: "/usr/local/bin/cue")
    check(p.contains("com.cue.clipd"), "label")
    check(p.contains("/usr/local/bin/cue"), "binary path")
    check(p.contains("record"), "record arg")
    check(p.contains("--daemon-child"), "daemon-child arg")
    check(p.contains("KeepAlive"), "KeepAlive")

    let args = ClipDaemon.recordChildArgs(interval: 0.5, max: 200, ttl: 30)
    eq(args, ["record", "--daemon-child", "--interval", "0.5", "--max", "200", "--ttl", "30"], "child args")
    let noTTL = ClipDaemon.recordChildArgs()
    check(!noTTL.contains("--ttl"), "无 ttl 时不传 --ttl")

    print("  ClipDaemon: OK")
}

// MARK: - ClipRules

func testClipRules() {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rules = ClipRules(directory: dir)

    check(rules.ignoreList.isEmpty, "初始忽略列表空")
    rules.addIgnore("WeChat")
    check(rules.shouldIgnore(app: "WeChat", bundleId: "com.tencent.xinWeChat"), "忽略命中 app 名")
    check(rules.shouldIgnore(app: "Other", bundleId: "com.tencent.xinWeChat"), "忽略命中 bundle")
    check(!rules.shouldIgnore(app: "Safari", bundleId: "com.apple.Safari"), "未命中不忽略")

    rules.addSensitive("password")
    check(rules.containsSensitive(text: "my password is x"), "敏感词命中")
    check(!rules.containsSensitive(text: "hello"), "敏感词未命中")

    let rules2 = ClipRules(directory: dir)  // 持久化重读
    check(rules2.shouldIgnore(app: "WeChat", bundleId: "x"), "忽略列表持久化")
    check(rules2.containsSensitive(text: "password"), "敏感词持久化")

    rules.clearIgnore()
    rules.clearSensitive()
    check(ClipRules(directory: dir).sensitiveList.isEmpty, "清空敏感词")
    check(ClipRules(directory: dir).ignoreList.isEmpty, "清空忽略列表")

    print("  ClipRules: OK")
}

// MARK: - main

print("cue 自测开始\n")
testHistoryStore()
testCLIParser()
testClipDaemon()
testClipRules()
print("\n结果: \(passes) 通过, \(failures) 失败")
exit(failures == 0 ? 0 : 1)
