import AppKit
import Foundation

// MARK: - 入口

let command = CueCommand(args: CommandLine.arguments)

switch command {
case .help:
    ClipCommand(opts: ClipOptions(action: .help)).printHelp()
case .version:
    print("cue 0.1.0")
case .clip(let opts):
    ClipCommand(opts: opts).run()
case .unknown(let cmd):
    fputs("未知命令: \(cmd)\n\n", stderr)
    fputs("用法: cue [list|show|add|edit|pin|unpin|delete|clear|export|import|paste|stats|prune|ignore|sensitive|record|ui|stop|status|autostart]\n", stderr)
    ClipCommand(opts: ClipOptions(action: .help)).printHelp()
    exit(1)
}
