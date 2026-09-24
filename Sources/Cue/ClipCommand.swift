import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 剪贴板历史命令（cue clip / cue）

struct ClipCommand {
    let opts: ClipOptions
    private let store: HistoryStore

    init(opts: ClipOptions) {
        self.opts = opts
        self.store = HistoryStore(maxEntries: opts.max)
    }

    func run() {
        for w in opts.warnings { fputs(w + "\n", stderr) }
        switch opts.action {
        case .help:
            printHelp()
        case .list:
            runList(recentOnly: opts.recentOnly)
        case .show:
            runShow()
        case .add:
            runAdd()
        case .edit:
            runEdit()
        case .pin:
            runPin(pinned: true)
        case .unpin:
            runPin(pinned: false)
        case .delete:
            runDelete()
        case .clear:
            runClear()
        case .export:
            runExport()
        case .import:
            runImport()
        case .paste:
            runPaste()
        case .stats:
            runStats()
        case .prune:
            runPrune()
        case .ignore:
            runRule(kind: .ignore)
        case .sensitive:
            runRule(kind: .sensitive)
        case .record:
            runRecord()
        case .ui:
            runUI()
        case .stop:
            runStop()
        case .status:
            runStatus()
        case .autostart:
            runAutostart()
        }
    }

    func printHelp() {
        print("""
        cue — 剪贴板历史管理

        用法:
          cue                        显示最近 20 条（等同 cue list）
          cue list                   列出全部（--search 关键词 / --limit N / --json / --pinned）
          cue show <id>              查看完整内容并复制到剪贴板（--no-copy 只看不复制）
          cue add "文本"              写入剪贴板并入库
          cue edit <id> "新文本"      修改内容，同步写入剪贴板
          cue pin <id>               置顶
          cue unpin <id>             取消置顶
          cue delete <id>            删除一条
          cue clear                  清空全部（默认需确认，--yes/-y 跳过）
          cue export [<path>]        导出全部（含内容）为 JSON（默认 ~/Desktop）
          cue import <file>          导入 JSON（同 id 跳过，--replace 覆盖）
          cue show <imgId>           图片条目可拷回剪贴板
          cue paste <id>             复制并模拟 Cmd+V 粘贴（需辅助功能权限）
          cue list --app Safari --type text  按来源/类型过滤列表
          cue stats                  查看统计（类型/来源 Top/近 7/30 天）
          cue prune [--ttl 30]       清理 N 天前的旧条目（置顶豁免）
          cue ignore <App>           App/包名 入库忽略（--clear 清空，无参查看）
          cue sensitive <词>          含敏感词的文本不入库（--clear 清空，无参查看）
          cue record                 监控模式：复制自动入库（--interval 可调，--max 调整上限）
          cue record --daemon        后台常驻记录（日志: ~/Library/Logs/cue/clipd.log）
          cue stop                   停止后台记录
          cue status                 查看后台记录状态
          cue autostart on/off       开机自启（LaunchAgent）
          cue ui                     交互式 TUI（↑↓选择/输入即搜索/回车复制/v粘贴/p置顶/d删除/u撤销）

        历史存储位置: \(HistoryStore.defaultDirectory().path)
        上限: 默认 500 条（--max 调整），置顶条目不受裁剪影响

        """)
    }

    // MARK: - 查

    private func runList(recentOnly: Bool) {
        let limit: Int? = recentOnly ? 20 : opts.limit
        var type: HistoryType?
        if let t = opts.typeFilter, !t.isEmpty {
            if let parsed = HistoryType(rawValue: t) {
                type = parsed
            } else {
                fputs("⚠️ 无法识别的类型: \(t)（可用 text / image / file）\n", stderr)
            }
        }
        let entries = store.list(search: opts.search, limit: limit, pinnedOnly: opts.pinnedOnly,
                                 app: opts.appFilter, type: type)

        if opts.json {
            for e in entries { print(jsonLine(e)) }
            return
        }
        if entries.isEmpty {
            print("暂无历史记录。")
            return
        }
        if recentOnly {
            let total = store.count
            print("最近 \(entries.count) 条（共 \(total) 条，cue list 查看全部）")
        } else {
            print("共 \(entries.count) 条记录：")
        }
        print("---")
        for (i, e) in entries.enumerated() {
            let pin = e.pinned ? "📌 " : "   "
            let time = formatTime(e.updatedAt)
            let app = (e.appName.isEmpty ? "—" : e.appName)
                .padding(toLength: 18, withPad: " ", startingAt: 0)
            print("\(String(format: "%3d", i + 1)) \(pin)\(time)  \(app) \(e.preview)")
        }
    }

    private func runShow() {
        guard let id = opts.id else {
            fputs("用法: cue show <id> [--no-copy] [--json]\n", stderr)
            exit(1)
        }
        guard let entry = store.get(id: id) else {
            fputs("❌ 条目不存在: \(id)\n", stderr)
            exit(1)
        }
        guard entry.type == .text, let content = store.content(id: id) else {
            if entry.type == .image, store.hasImageData(id: id) {
                if let data = store.contentImage(id: id) {
                    if opts.json {
                        let dict: [String: Any] = [
                            "id": entry.id, "type": "image", "app": entry.appName,
                            "bytes": data.count, "pinned": entry.pinned,
                            "created_at": Int(entry.createdAt.timeIntervalSince1970),
                            "updated_at": Int(entry.updatedAt.timeIntervalSince1970)
                        ]
                        print(json(from: dict))
                        return
                    }
                    print("🖼 图片条目 (\(data.count / 1024) KB)  来源: \(entry.appName)  时间: \(formatTime(entry.updatedAt))")
                    if !opts.noCopy {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        if pb.setData(data, forType: .png) {
                            print("→ 图片已复制到剪贴板")
                        } else {
                            fputs("⚠️ 剪贴板写入失败\n", stderr)
                        }
                    }
                    return
                }
            }
            print("类型: \(entry.type.rawValue)  来源: \(entry.appName)  时间: \(formatTime(entry.updatedAt))（无内容数据）")
            return
        }

        if opts.json {
            let dict: [String: Any] = [
                "id": entry.id,
                "app": entry.appName,
                "bundle_id": entry.bundleId,
                "type": entry.type.rawValue,
                "pinned": entry.pinned,
                "created_at": Int(entry.createdAt.timeIntervalSince1970),
                "updated_at": Int(entry.updatedAt.timeIntervalSince1970),
                "content": content
            ]
            print(json(from: dict))
            return
        }

        print(content)
        if !opts.noCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            if pb.setString(content, forType: .string) {
                print("→ 已复制到剪贴板")
            } else {
                fputs("⚠️ 剪贴板写入失败\n", stderr)
            }
        }
    }

    // MARK: - 增

    private func runAdd() {
        guard let text = opts.text, !text.isEmpty else {
            fputs("用法: cue add \"文本\"\n", stderr)
            exit(1)
        }
        let app = FrontAppDetector.current()
        let entry = store.add(text: text, appName: app.name, bundleId: app.bundleId)

        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            print("✅ 已写入剪贴板并入库: \(entry.id)")
        } else {
            fputs("⚠️ 剪贴板写入失败，记录已保存\n", stderr)
        }
    }

    // MARK: - 改

    private func runEdit() {
        guard let id = opts.id, let text = opts.text, !text.isEmpty else {
            fputs("用法: cue edit <id> \"新文本\"\n", stderr)
            exit(1)
        }
        guard store.update(id: id, text: text) != nil else {
            fputs("❌ 条目不存在: \(id)\n", stderr)
            exit(1)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            print("✅ 已更新并复制到剪贴板: \(id)")
        } else {
            fputs("⚠️ 剪贴板写入失败，记录已更新\n", stderr)
        }
    }

    private func runPin(pinned: Bool) {
        guard let id = opts.id else {
            fputs("用法: cue \(pinned ? "pin" : "unpin") <id>\n", stderr)
            exit(1)
        }
        guard let entry = store.setPinned(id: id, pinned: pinned) else {
            fputs("❌ 条目不存在: \(id)\n", stderr)
            exit(1)
        }
        print(pinned ? "📌 已置顶: \(entry.preview)" : "已取消置顶: \(entry.preview)")
    }

    // MARK: - 删

    private func runDelete() {
        guard let id = opts.id else {
            fputs("用法: cue delete <id>\n", stderr)
            exit(1)
        }
        guard store.delete(id: id) else {
            fputs("❌ 条目不存在: \(id)\n", stderr)
            exit(1)
        }
        print("🗑 已删除: \(id)")
    }

    private func runClear() {
        let n = store.count
        guard n > 0 else {
            print("暂无历史记录。")
            return
        }
        if !opts.yes {
            print("Clear all \(n) items? [y/N] ", terminator: "")
            fflush(stdout)
            guard let line = readLine(), line.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }
        let removed = store.clear()
        print("已清空 \(removed) 条记录。")
    }

    static let maxImageBytes = 25 * 1_048_576

    static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    // MARK: - 导出 / 导入

    private func runExport() {
        let path = opts.id ?? defaultExportPath()
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        do {
            let n = try store.export(to: url)
            print("✅ 已导出 \(n) 条记录 → \(url.path)")
            print("   导入: cue import \(url.path)")
        } catch {
            fputs("❌ 导出失败: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func runImport() {
        guard let path = opts.id, !path.isEmpty else {
            fputs("用法: cue import <file.json> [--replace]\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        do {
            let (imported, skipped) = try store.import(from: url, replace: opts.replace)
            print("✅ 导入 \(imported) 条\(skipped > 0 ? "，跳过 \(skipped) 条（同 id 已存在）" : "")")
        } catch {
            fputs("❌ 导入失败: \(error.localizedDescription)（文件不是有效的导出 JSON？）\n", stderr)
            exit(1)
        }
    }

    private func defaultExportPath() -> String {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return desktop.appendingPathComponent("cue-clipboard-\(fmt.string(from: Date())).json").path
    }

    // MARK: - 统计 / 清理 / 规则

    private func runStats() {
        let s = ClipStats.compute(from: store.entries)
        if opts.json {
            var top: [[String: Any]] = []
            for a in s.topApps {
                top.append(["app": a.name, "count": a.count])
            }
            let dict: [String: Any] = [
                "total": s.total, "text": s.text, "image": s.image, "file": s.file,
                "pinned": s.pinned, "today": s.today, "last_7_days": s.last7Days,
                "last_30_days": s.last30Days, "top_apps": top
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
            return
        }
        print("📊 共 \(s.total) 条：文本 \(s.text) · 图片 \(s.image) · 文件 \(s.file) · 置顶 \(s.pinned)")
        print("⏱ 今日 \(s.today) · 近 7 天 \(s.last7Days) · 近 30 天 \(s.last30Days)")
        if !s.topApps.isEmpty {
            let apps = s.topApps.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
            print("🏆 Top 来源: \(apps)")
        }
    }

    private func runPaste() {
        guard let id = opts.id else {
            fputs("用法: cue paste <id>\n", stderr)
            exit(1)
        }
        guard let entry = store.get(id: id) else {
            fputs("❌ 条目不存在: \(id)\n", stderr)
            exit(1)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        var copied = false
        if entry.type == .text, let content = store.content(id: id), !content.isEmpty {
            copied = pb.setString(content, forType: .string)
        } else if entry.type == .image, let data = store.contentImage(id: id) {
            copied = pb.setData(data, forType: .png)
        }
        guard copied else {
            fputs("❌ 无法写入剪贴板（条目可能无内容）\n", stderr)
            exit(1)
        }
        print("✅ 已写入剪贴板，准备粘贴…")

        guard AXIsProcessTrusted() else {
            fputs("⚠️ 需要「辅助功能」权限才能自动粘贴。\n", stderr)
            fputs("   系统设置 > 隐私与安全性 > 辅助功能 > 勾选 cue；然后手动 Cmd+V（内容已在剪贴板）\n", stderr)
            return
        }
        NSWorkspace.shared.frontmostApplication?.activate(options: [.activateIgnoringOtherApps])
        usleep(250_000)
        postCommandV()
        print("📋 已发送 Cmd+V")
    }

    private func postCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }

    private func runPrune() {
        let ttl = opts.ttlDays > 0 ? opts.ttlDays : 30
        let removed = store.pruneOlderThan(days: ttl)
        if removed > 0 {
            print("🧹 已清理 \(removed) 条超过 \(ttl) 天的旧记录（置顶豁免）")
        } else {
            print("ℹ️ 没有超过 \(ttl) 天的记录需要清理")
        }
    }

    private enum RuleKind {
        case ignore, sensitive
    }

    private func runRule(kind: RuleKind) {
        let rules = ClipRules()
        let isIgnore = kind == .ignore
        let title = isIgnore ? "忽略来源" : "敏感词"
        let noun = isIgnore ? "来源" : "词"

        if opts.clearFlag {
            if isIgnore { rules.clearIgnore() } else { rules.clearSensitive() }
            print("✅ 已清空\(title)列表")
            return
        }
        guard let word = opts.id, !word.isEmpty else {
            let list = isIgnore ? rules.ignoreList : rules.sensitiveList
            if list.isEmpty {
                print("当前\(title)列表为空。")
                print("  添加: cue \(isIgnore ? "ignore" : "sensitive") <\(noun)>")
            } else {
                print("\(title)列表（共 \(list.count) 条）:")
                for (i, item) in list.enumerated() {
                    print("  \(i + 1). \(item)")
                }
            }
            return
        }
        if isIgnore {
            rules.addIgnore(word)
            print("✅ 已添加忽略来源: \(word)（含此字样的 App 名/包名不再入库）")
        } else {
            rules.addSensitive(word)
            print("✅ 已添加敏感词: \(word)（含此词文本不再入库）")
        }
    }

    // MARK: - record（监控入库）

    private func runRecord() {
        // 后台守护模式：父进程启动子进程后立即退出
        if opts.daemon {
            if ClipDaemon.isRunning() {
                print("ℹ️ 后台记录已在运行（PID: \(ClipDaemon.readPid() ?? 0)）")
                return
            }
            if ClipDaemon.startDaemon(interval: opts.interval, max: opts.max, ttl: opts.ttlDays) {
                var started = false
                for _ in 0..<30 {
                    if ClipDaemon.isRunning() { started = true; break }
                    usleep(100_000)
                }
                if started {
                    if let pid = ClipDaemon.readPid() {
                        print("✅ 后台记录已启动 (PID: \(pid))")
                        print("   日志: \(ClipDaemon.logFileURL.path)")
                        print("   cue status 查看状态，cue stop 停止")
                    } else {
                        print("✅ 后台记录已启动")
                    }
                } else {
                    fputs("❌ 后台记录启动失败：子进程未能正常运行。\n", stderr)
                    fputs("   日志: \(ClipDaemon.logFileURL.path)\n", stderr)
                    fputs("   常见原因：已有其它记录实例在运行（可用 cue status 确认）\n", stderr)
                    exit(1)
                }
            }
            return
        }

        // 前台监控与守护子进程都做单例登记，避免两个进程同时写同一份索引
        guard ClipDaemon.acquireSingleInstance() else {
            fputs("❌ 已存在其它记录进程，本实例退出（避免重复入库）。\n", stderr)
            fputs("   若为后台记录在运行，可先 `cue stop` 再前台监控。\n", stderr)
            exit(1)
        }
        if opts.daemonChild {
            setvbuf(stdout, nil, _IONBF, 0)   // 日志实时写入文件（禁用缓冲）
        }

        signal(SIGINT) { _ in
            if ClipDaemon.readPid() == getpid() {
                ClipDaemon.removePidFile()
            }
            print("\n已停止。")
            exit(0)
        }
        signal(SIGTERM) { _ in
            if ClipDaemon.readPid() == getpid() {
                ClipDaemon.removePidFile()
            }
            exit(0)
        }

        let watcher = ClipboardWatcher(interval: opts.interval)
        let pb = NSPasteboard.general
        let rules = ClipRules()

        watcher.onChange = { event in
            if rules.shouldIgnore(app: event.appName, bundleId: event.bundleId) { return }
            if event.isText, let text = pb.string(forType: .string), !text.isEmpty {
                if rules.containsSensitive(text: text) { return }
                let entry = store.add(text: text, appName: event.appName, bundleId: event.bundleId)
                if opts.json {
                    print(recordJSON(type: "text", entry: entry, app: event.appName))
                } else {
                    print("📋 \(formatTime(entry.updatedAt)) [\(event.appName)] \(entry.preview)")
                }
            } else if event.isImage {
                let imageData = Self.pngData(from: pb) ?? Data()
                let entry = store.addMetadata(type: .image, appName: event.appName,
                                              bundleId: event.bundleId,
                                              data: !imageData.isEmpty && imageData.count <= Self.maxImageBytes ? imageData : nil)
                if opts.json {
                    print(recordJSON(type: "image", entry: entry, app: event.appName))
                } else {
                    let sizeNote = !imageData.isEmpty && imageData.count > Self.maxImageBytes ? "（过大，未存图）" : ""
                    print("🖼 \(formatTime(entry.updatedAt)) [\(event.appName)] \(entry.preview)\(sizeNote)")
                }
            } else {
                let entry = store.addMetadata(type: .file, appName: event.appName, bundleId: event.bundleId)
                if opts.json {
                    print(recordJSON(type: "file", entry: entry, app: event.appName))
                } else {
                    print("📄 \(formatTime(entry.updatedAt)) [\(event.appName)] \(entry.preview)")
                }
            }
        }

        if opts.ttlDays > 0 {
            let n = store.pruneOlderThan(days: opts.ttlDays)
            if n > 0 { print("🧹 TTL 清理 \(n) 条（超过 \(opts.ttlDays) 天）") }
            let ttl = opts.ttlDays
            let pruneTimer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
                let m = store.pruneOlderThan(days: ttl)
                if m > 0 { print("🧹 TTL 清理 \(m) 条") }
            }
            RunLoop.current.add(pruneTimer, forMode: .common)
        }

        print("剪贴板历史记录中（Ctrl+C 退出，上限 \(opts.max) 条" +
              (opts.ttlDays > 0 ? "，自动清理 >\(opts.ttlDays) 天" : "") + "）")
        watcher.start()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - 守护进程管理 / UI

    private func runStop() {
        if ClipDaemon.stop() {
            if ClipDaemon.autostartEnabled() {
                print("🛑 后台记录已停止。")
                print("ℹ️ 开机自启仍开启（launchd 会自动拉起记录进程）；彻底停止请先 `cue autostart off`")
            } else {
                print("🛑 后台记录已停止。")
            }
        } else {
            print("ℹ️ 后台记录未在运行。")
        }
    }

    private func runStatus() {
        if let pid = ClipDaemon.readPid(), ClipDaemon.isRunning() {
            print("✅ 后台记录运行中 (PID: \(pid))")
            print("   历史条数: \(store.count)")
            print("   日志: \(ClipDaemon.logFileURL.path)")
            print("   开机自启: \(ClipDaemon.autostartEnabled() ? "已开启" : "未开启")")
        } else {
            print("⏸ 后台记录未运行。")
            print("   启动: cue record --daemon")
        }
        if let newest = store.entries.max(by: { $0.updatedAt < $1.updatedAt }) {
            print("   最近记录: \(formatTime(newest.updatedAt))")
            if let note = Self.stalenessNote(lastUpdate: newest.updatedAt, now: Date()) {
                fputs(note + "\n", stderr)
            }
        }
    }

    static func stalenessNote(lastUpdate: Date?, now: Date, threshold: TimeInterval = 24 * 3600) -> String? {
        guard let last = lastUpdate else { return nil }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > threshold else { return nil }
        let hours = elapsed / 3600
        let human: String
        if hours >= 24 {
            human = String(format: "%.1f 天", hours / 24)
        } else {
            human = String(format: "%.0f 小时", hours)
        }
        return "⚠️ 最近记录在 \(human) 前，已超过 \(Int(threshold / 3600)) 小时无新增——记录可能已断更，请确认后台记录是否运行（`cue record --daemon` 启动、`cue autostart on` 开机自启）"
    }

    private func runAutostart() {
        guard let mode = opts.id, mode == "on" || mode == "off" else {
            fputs("用法: cue autostart on|off\n", stderr)
            exit(1)
        }
        let binary = ClipDaemon.currentExecutablePath() ?? URL(fileURLWithPath: CommandLine.arguments[0]).path
        if mode == "on" {
            if !ClipDaemon.autostartEnabled() {
                _ = ClipDaemon.stop()
            }
            if ClipDaemon.installLaunchAgent(binaryPath: binary) {
                print("✅ 开机自启已开启")
                print("   plist: \(ClipDaemon.launchAgentURL.path)")
                print("   下次登录自动记录剪贴板历史")
            } else if ClipDaemon.autostartEnabled() && ClipDaemon.isRunning() {
                print("✅ 开机自启已开启（记录进程运行中）")
            } else {
                fputs("❌ 开机自启开启失败，请检查 plist 与 launchctl 状态\n", stderr)
                exit(1)
            }
        } else {
            if ClipDaemon.removeLaunchAgent() {
                print("✅ 开机自启已关闭")
            } else {
                fputs("❌ 开机自启关闭失败\n", stderr)
                exit(1)
            }
        }
    }

    private func runUI() {
        let tui = ClipTUI()
        tui.run()
    }

    // MARK: - 输出辅助

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func jsonLine(_ e: HistoryEntry) -> String {
        json(from: [
            "id": e.id,
            "app": e.appName,
            "bundle_id": e.bundleId,
            "type": e.type.rawValue,
            "pinned": e.pinned,
            "created_at": Int(e.createdAt.timeIntervalSince1970),
            "updated_at": Int(e.updatedAt.timeIntervalSince1970),
            "preview": e.preview
        ])
    }

    private func recordJSON(type: String, entry: HistoryEntry, app: String) -> String {
        json(from: [
            "event": "clip_recorded",
            "id": entry.id,
            "app": app,
            "type": type,
            "pinned": entry.pinned,
            "time": Int(entry.updatedAt.timeIntervalSince1970),
            "preview": entry.preview
        ])
    }

    private func json(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
