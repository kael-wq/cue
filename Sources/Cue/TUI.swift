import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - 按键

enum Key: Equatable {
    case up, down, left, right, pgUp, pgDn, home, end
    case enter, esc, backspace, ctrlC
    case char(Character)
}

/// 字节流 → 按键 的增量解析器（处理箭头/翻页/Home/End 的 CSI/SS3 序列与多字节 UTF-8）
struct KeyParser {
    private enum State {
        case idle
        case esc
        case ss3
        case csi([UInt8])
        case utf8(bytes: [UInt8], total: Int)
    }

    private var state = State.idle

    mutating func feed(_ byte: UInt8) -> Key? {
        switch state {
        case .idle:
            if byte == 0x1B { state = .esc; return nil }
            if byte == 0x03 { return .ctrlC }
            if byte == 0x0D || byte == 0x0A { return .enter }
            if byte == 0x7F || byte == 0x08 { return .backspace }
            if byte < 0x20 { return nil }
            if byte < 0x80 { return .char(Character(UnicodeScalar(byte))) }
            let total: Int
            if byte >= 0xF0 { total = 4 } else if byte >= 0xE0 { total = 3 } else { total = 2 }
            state = .utf8(bytes: [byte], total: total)
            return nil
        case .esc:
            if byte == 0x5B { state = .csi([]); return nil }   // ESC [
            if byte == 0x4F { state = .ss3; return nil }       // ESC O
            state = .idle
            return .esc
        case .ss3:
            state = .idle
            switch byte {
            case 0x48: return .home
            case 0x46: return .end
            default: return nil
            }
        case .csi(var buf):
            if byte >= 0x40, byte <= 0x7E {
                state = .idle
                return Self.mapCSI(buf, final: byte)
            }
            buf.append(byte)
            state = .csi(buf)
            return nil
        case .utf8(var buf, let total):
            buf.append(byte)
            if buf.count >= total {
                state = .idle
                if let s = String(bytes: buf, encoding: .utf8), let ch = s.first {
                    return .char(ch)
                }
                return nil
            }
            state = .utf8(bytes: buf, total: total)
            return nil
        }
    }

    /// 超时后冲掉未完成的转义/组合序列：单独的 ESC 视为 .esc，残片丢弃
    mutating func flushPending() -> Key? {
        switch state {
        case .esc:
            state = .idle
            return .esc
        default:
            state = .idle
            return nil
        }
    }

    static func mapCSI(_ params: [UInt8], final: UInt8) -> Key? {
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x7E:
            switch params.first {
            case 0x31: return .home      // ESC[1~
            case 0x34: return .end       // ESC[4~
            case 0x35: return .pgUp      // ESC[5~
            case 0x36: return .pgDn      // ESC[6~
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - 终端原语

struct Terminal {
    static func isTTY(_ fd: Int32 = STDIN_FILENO) -> Bool {
        isatty(fd) == 1
    }

    static func enableRaw(_ fd: Int32 = STDIN_FILENO) -> termios? {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return nil }
        var raw = t
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | IEXTEN)
        raw.c_oflag &= ~tcflag_t(OPOST)
        withUnsafeMutableBytes(of: &raw.c_cc) { buf in
            buf.storeBytes(of: 1, toByteOffset: Int(VMIN), as: cc_t.self)
            buf.storeBytes(of: 0, toByteOffset: Int(VTIME), as: cc_t.self)
        }
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return nil }
        return t
    }

    static func restore(_ saved: termios, _ fd: Int32 = STDIN_FILENO) {
        var t = saved
        tcsetattr(fd, TCSANOW, &t)
    }

    static func size() -> (cols: Int, rows: Int) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 else { return (80, 24) }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    static func nextKey(timeoutMS: Int = 200) -> [UInt8]? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(timeoutMS))
        guard r > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return nil }
        return Array(buf.prefix(n))
    }
}

// MARK: - 剪贴板 TUI

/// `cue ui`：全屏交互列表。零第三方依赖（raw mode + ANSI 自绘）。
struct ClipTUI {
    let directory: URL
    var store: HistoryStore

    private var query = ""
    private var selection = 0
    private var visible: [HistoryEntry] = []
    private var statusMsg = ""
    private var tombstone: HistoryStore.Tombstone?
    private var lastKeyHint = ""

    init(directory: URL = HistoryStore.defaultDirectory()) {
        self.directory = directory
        self.store = HistoryStore(directory: directory)
    }

    // MARK: - 运行

    func run() {
        guard Terminal.isTTY(STDIN_FILENO), Terminal.isTTY(STDOUT_FILENO) else {
            fputs("❌ cue ui 需要交互式终端。\n", stderr)
            exit(1)
        }
        let saved = Terminal.enableRaw()
        guard saved != nil else {
            fputs("❌ 无法进入原始终端模式\n", stderr)
            exit(1)
        }
        restoreTerminalOnSignal(saved!)
        fputs("\u{1B}[?25l", stdout)
        fflush(stdout)

        var tui = self
        var parser = KeyParser()
        defer { tui.teardown(saved!) }
        tui.refresh(keepSelection: true)

        loop: while true {
            tui.draw()
            if let bytes = Terminal.nextKey(timeoutMS: 200) {
                for b in bytes {
                    if let key = parser.feed(b) {
                        let shouldQuit = tui.handle(key)
                        if shouldQuit { break loop }
                    }
                }
            } else {
                if let pending = parser.flushPending() {
                    let shouldQuit = tui.handle(pending)
                    if shouldQuit { break loop }
                } else {
                    tui.refresh(keepSelection: true)
                }
            }
        }
    }

    private func teardown(_ saved: termios) {
        fputs("\u{1B}[?25h\u{1B}[0m\u{1B}[J", stdout)
        fflush(stdout)
        Terminal.restore(saved)
    }

    // MARK: - 状态维护

    private mutating func refresh(keepSelection: Bool) {
        store = HistoryStore(directory: directory)
        let all = store.list(search: query.isEmpty ? nil : query)
        visible = all
        let newSel = ClipTUI.clamped(selection: keepSelection ? selection : 0, count: all.count)
        if all.isEmpty { selection = 0 } else { selection = newSel }
        if statusMsg.isEmpty {
            lastKeyHint = all.isEmpty ? "暂无记录 — q 退出" : "↑↓ 选择 · 输入搜索 · 回车复制 · v 粘贴 · p 置顶 · d 删除(u 撤销) · q 退出"
        }
    }

    private mutating func handle(_ key: Key) -> Bool {
        statusMsg = ""
        switch key {
        case .up, .char("k"): if selection > 0 { selection -= 1 }
        case .down, .char("j"): if selection + 1 < visible.count { selection += 1 }
        case .pgUp: selection = max(0, selection - 20)
        case .pgDn: selection = min(visible.count - 1, selection + 20)
        case .home, .char("g"): selection = 0
        case .end, .char("G"): selection = max(0, visible.count - 1)
        case .char("q"): return true
        case .ctrlC: return true
        case .esc:
            if !query.isEmpty {
                query = ""
                refresh(keepSelection: true)
            } else {
                return true
            }
        case .backspace:
            if !query.isEmpty {
                query.removeLast()
                refresh(keepSelection: false)
            }
        case .char(let c):
            if c.isPrintableForQuery {
                query.append(c)
                refresh(keepSelection: false)
            }
        case .enter, .char("y"):
            copySelected()
        case .char("v"):
            copySelected(); pasteToFront()
        case .char("p"):
            togglePin()
        case .char("d"):
            deleteSelected()
        case .char("u"):
            undoDelete()
        case .char("r"):
            refresh(keepSelection: true); statusMsg = "已刷新"
        default:
            break
        }
        return false
    }

    // MARK: - 动作

    private mutating func selectedID() -> String? {
        guard !visible.isEmpty, visible.indices.contains(selection) else { return nil }
        return visible[selection].id
    }

    private mutating func copySelected() {
        guard let id = selectedID(), let entry = store.get(id: id) else {
            statusMsg = "⚠️ 没有可复制的条目"
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        var ok = false
        if entry.type == .text, let content = store.content(id: id), !content.isEmpty {
            ok = pb.setString(content, forType: .string)
            statusMsg = ok ? "✅ 已复制到剪贴板（\(content.count) 字符）" : "⚠️ 剪贴板写入失败"
        } else if entry.type == .image, let data = store.contentImage(id: id) {
            ok = pb.setData(data, forType: .png)
            statusMsg = ok ? "🖼 图片已复制到剪贴板（\(data.count / 1024) KB）" : "⚠️ 剪贴板写入失败"
        } else {
            statusMsg = "⚠️ 该条目没有可复制的内容"
        }
    }

    private mutating func pasteToFront() {
        guard AXIsProcessTrusted() else {
            statusMsg = "⚠️ 粘贴需「辅助功能」权限：系统设置 > 隐私与安全性 > 辅助功能"
            return
        }
        NSWorkspace.shared.frontmostApplication?.activate(options: [.activateIgnoringOtherApps])
        usleep(250_000)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
        statusMsg = "📋 已发送 Cmd+V"
    }

    private mutating func togglePin() {
        guard let id = selectedID(), let entry = store.get(id: id) else {
            statusMsg = "⚠️ 无选中条目"
            return
        }
        _ = store.setPinned(id: id, pinned: !entry.pinned)
        statusMsg = !entry.pinned ? "📌 已置顶" : "已取消置顶"
        refresh(keepSelection: true)
    }

    private mutating func deleteSelected() {
        guard let id = selectedID() else {
            statusMsg = "⚠️ 无选中条目"
            return
        }
        tombstone = store.tombstone(id: id)
        if tombstone != nil {
            statusMsg = "🗑 已删除 — 按 u 撤销"
        } else {
            statusMsg = "⚠️ 删除失败"
        }
        refresh(keepSelection: true)
    }

    private mutating func undoDelete() {
        guard let stone = tombstone else {
            statusMsg = "没有可撤销的删除"
            return
        }
        if store.restore(stone) {
            tombstone = nil
            statusMsg = "↩️ 已撤销删除"
        } else {
            statusMsg = "⚠️ 撤销失败（可能已被其它进程改动）"
        }
        refresh(keepSelection: true)
    }

    // MARK: - 渲染

    private mutating func draw() {
        let (cols, rows) = Terminal.size()
        let width = max(20, cols - 1)
        let maxRows = max(1, rows - 3)
        var lines: [String] = []

        let total = store.count
        let title = "📋 cue TUI — 剪贴板历史（共 \(total) 条\(query.isEmpty ? "" : "，过滤: \(query)")）"
        lines.append("\u{1B}[1;33m" + Self.clip(title, to: width) + "\u{1B}[0m")

        let rangeStart = max(0, selection - maxRows / 2)
        let slice = Array(visible.dropFirst(rangeStart).prefix(maxRows))

        if visible.isEmpty {
            lines.append("  （无匹配记录）")
        }
        for (idx, entry) in slice.enumerated() {
            let i = rangeStart + idx
            let isSel = i == selection
            let pin = entry.pinned ? "📌" : "  "
            let time = Self.fmtTime(entry.updatedAt)
            let app = Self.pad(String(entry.appName.prefix(14)), to: 14)

            let prefix = String(format: "%3d  ", i + 1)
            let prefixCells = Self.cellWidth(prefix) + Self.cellWidth(pin) + 1
                + Self.cellWidth(time) + 2 + 14 + 1
            let previewWidth = max(6, width - prefixCells)
            let preview = Self.clip(entry.preview, to: previewWidth)

            var base = "\(prefix)\(pin) \(time)  \(app) \(preview)"
            if isSel {
                base = Self.pad(base, to: width)
                lines.append("\u{1B}[7m\(base)\u{1B}[0m")
            } else {
                lines.append(base)
            }
        }

        while lines.count < maxRows + 1 { lines.append("") }

        let hint = statusMsg.isEmpty ? lastKeyHint : statusMsg
        lines.append("\u{1B}[2m" + Self.pad(Self.clip(hint, to: width), to: width) + "\u{1B}[0m")

        var frame = "\u{1B}[H\u{1B}[J"
        frame += lines.prefix(maxRows + 2).joined(separator: "\r\n")
        fputs(frame, stdout)
        fflush(stdout)
    }

    // MARK: - 纯函数（可单测）

    static func clamped(selection: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, selection), count - 1)
    }

    static func clip(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if cellWidth(text) <= width { return text }
        var out = ""
        var used = 0
        for ch in text {
            let w = cellWidth(String(ch))
            if used + w > width - 1 { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    static func pad(_ text: String, to width: Int) -> String {
        let w = cellWidth(text)
        guard w < width else { return text }
        return text + String(repeating: " ", count: width - w)
    }

    static func cellWidth(_ text: String) -> Int {
        var sum = 0
        for scalar in text.unicodeScalars {
            sum += Self.isWide(scalar) ? 2 : 1
        }
        return sum
    }

    private static func isWide(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v >= 0x1F000 { return true }
        if v >= 0x1100 && v <= 0x115F { return true }
        if v == 0x2329 || v == 0x232A { return true }
        if v >= 0x2E80 && v <= 0xA4CF && v != 0x303F { return true }
        if v >= 0xAC00 && v <= 0xD7A3 { return true }
        if v >= 0xF900 && v <= 0xFAFF { return true }
        if v >= 0xFE30 && v <= 0xFE6F { return true }
        if v >= 0xFF00 && v <= 0xFF60 { return true }
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }
        if v >= 0x20000 && v <= 0x3FFFD { return true }
        return false
    }

    static func fmtTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - 信号恢复

private var gSavedTermios: termios?

private func restoreTerminalOnSignal(_ saved: termios) {
    gSavedTermios = saved
    signal(SIGINT) { _ in exitTUIRaw() }
    signal(SIGTERM) { _ in exitTUIRaw() }
    signal(SIGHUP) { _ in exitTUIRaw() }
}

private func exitTUIRaw() -> Never {
    if let t = gSavedTermios {
        fputs("\u{1B}[?25h\u{1B}[0m\u{1B}[J", stdout)
        fflush(stdout)
        Terminal.restore(t)
    }
    exit(130)
}

private extension Character {
    var isPrintableForQuery: Bool {
        !isNewline && unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}
