import Foundation

// MARK: - 命令选项

struct ClipOptions {
    var action: ClipAction = .list
    var recentOnly: Bool = true      // 无子命令时只看最近 20 条
    var search: String?
    var limit: Int?
    var json: Bool = false
    var pinnedOnly: Bool = false
    var noCopy: Bool = false
    var yes: Bool = false
    var replace: Bool = false
    var appFilter: String?          // list --app
    var typeFilter: String?         // list --type text|image|file
    var ttlDays: Int = 0            // record/prune --ttl N
    var clearFlag: Bool = false     // ignore/sensitive --clear
    var interval: TimeInterval = 0.3
    var max: Int = 500
    var id: String?
    var text: String?
    var daemon: Bool = false          // record --daemon 后台常驻
    var daemonChild: Bool = false     // 内部参数：守护子进程
    var warnings: [String] = []
}

enum ClipAction: String {
    case list, show, add, edit, pin, unpin, delete, clear, export, `import`, paste, record, stop, status, autostart, stats, prune, ignore, sensitive, ui, help
}

// MARK: - 参数解析

enum CLIParser {
    static func parse(_ args: [String]) -> ClipOptions {
        var opts = ClipOptions()
        var positionals: [String] = []

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--search":
                if i + 1 < args.count { opts.search = args[i + 1]; i += 1 }
            case let a where a.hasPrefix("--search="):
                opts.search = String(a.dropFirst("--search=".count))
            case "--limit":
                if i + 1 < args.count { opts.limit = Int(args[i + 1]); i += 1 }
            case let a where a.hasPrefix("--limit="):
                opts.limit = Int(String(a.dropFirst("--limit=".count)))
            case "--json":
                opts.json = true
            case "--pinned":
                opts.pinnedOnly = true
            case "--no-copy":
                opts.noCopy = true
            case "--yes", "-y":
                opts.yes = true
            case "--replace":
                opts.replace = true
            case "--app":
                if i + 1 < args.count { opts.appFilter = args[i + 1]; i += 1 }
            case let a where a.hasPrefix("--app="):
                opts.appFilter = String(a.dropFirst("--app=".count))
            case "--type":
                if i + 1 < args.count { opts.typeFilter = args[i + 1]; i += 1 }
            case let a where a.hasPrefix("--type="):
                opts.typeFilter = String(a.dropFirst("--type=".count))
            case "--ttl":
                if i + 1 < args.count { opts.ttlDays = Int(args[i + 1]) ?? 0; i += 1 }
            case let a where a.hasPrefix("--ttl="):
                opts.ttlDays = Int(String(a.dropFirst("--ttl=".count))) ?? 0
            case "--clear":
                opts.clearFlag = true
            case "--interval":
                if i + 1 < args.count { opts.interval = Double(args[i + 1]) ?? 0.3; i += 1 }
            case let a where a.hasPrefix("--interval="):
                opts.interval = Double(String(a.dropFirst("--interval=".count))) ?? 0.3
            case "--max":
                if i + 1 < args.count { opts.max = Int(args[i + 1]) ?? 500; i += 1 }
            case let a where a.hasPrefix("--max="):
                opts.max = Int(String(a.dropFirst("--max=".count))) ?? 500
            case "--daemon":
                opts.daemon = true
            case "--daemon-child":
                opts.daemonChild = true
            case "--help", "-h":
                opts.action = .help
            default:
                positionals.append(a)
            }
            i += 1
        }

        // 第一个位置参数是子命令
        if let first = positionals.first, let action = ClipAction(rawValue: first), action != .help {
            opts.action = action
            opts.recentOnly = false
            positionals.removeFirst()
        }

        switch opts.action {
        case .add:
            opts.text = positionals.first
        case .edit:
            if positionals.count >= 1 { opts.id = positionals[0] }
            if positionals.count >= 2 { opts.text = positionals[1] }
        default:
            opts.id = positionals.first
        }

        let expectedPositionals: Int
        switch opts.action {
        case .add:
            expectedPositionals = 1
        case .edit:
            expectedPositionals = 2
        case .show, .pin, .unpin, .delete, .export, .import, .paste, .ignore, .sensitive, .autostart:
            expectedPositionals = 1
        default:
            expectedPositionals = 0
        }

        if positionals.count > expectedPositionals {
            let extra = positionals[expectedPositionals...].joined(separator: " ")
            opts.warnings.append("⚠️ 无法识别的参数被忽略: \(extra)")
        }
        return opts
    }
}

// MARK: - 入口命令

enum CueCommand {
    case clip(ClipOptions)
    case help
    case version
    case unknown(String)

    init(args: [String]) {
        // args[0] 是程序路径
        let rest = Array(args.dropFirst())
        if rest.isEmpty {
            self = .clip(ClipOptions())   // 默认显示最近 20 条
            return
        }
        switch rest[0] {
        case "--help", "-h":
            self = .help
        case "--version", "-v":
            self = .version
        case "clip":
            self = .clip(CLIParser.parse(Array(rest.dropFirst())))
        case let sub where ClipAction(rawValue: sub) != nil || sub.hasPrefix("-"):
            // 直接 `cue list` / `cue show ...` 等（省略 clip 前缀）
            self = .clip(CLIParser.parse(rest))
        default:
            self = .unknown(rest[0])
        }
    }
}
