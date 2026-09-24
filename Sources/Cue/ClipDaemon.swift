import Foundation

/// 剪贴板记录守护进程管理：后台常驻 record、PID 文件、日志、LaunchAgent 自启
struct ClipDaemon {
    static let label = "com.cue.clipd"

    // MARK: - 路径

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("cue", isDirectory: true)
    }

    static var pidFileURL: URL {
        supportDir.appendingPathComponent("clipd.pid")
    }

    static var logFileURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/cue")
        return base.appendingPathComponent("clipd.log")
    }

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: - PID 文件

    @discardableResult
    static func writePidFile(pid: Int32) -> Bool {
        if let existing = readPid(), existing != pid, kill(existing, 0) == 0 {
            return false
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
        return true
    }

    static func readPid() -> Int32? {
        guard let s = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    static func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    static func isRunning() -> Bool {
        guard let pid = readPid() else { return false }
        return kill(pid, 0) == 0
    }

    @discardableResult
    static func acquireSingleInstance() -> Bool {
        if !otherRecordPIDs(excluding: getpid()).isEmpty {
            return false
        }
        return writePidFile(pid: getpid())
    }

    static func otherRecordPIDs(excluding excluded: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "record --daemon-child"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }
            .filter { $0 != excluded }
    }

    // MARK: - 启动 / 停止

    static func currentExecutablePath() -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(buf.count)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        if let resolved = realpath(buf, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return String(cString: buf)
    }

    static func recordChildArgs(interval: TimeInterval = 0.3, max: Int = 500, ttl: Int = 0) -> [String] {
        var args = ["record", "--daemon-child",
                    "--interval", String(format: "%g", interval),
                    "--max", "\(max)"]
        if ttl > 0 {
            args += ["--ttl", "\(ttl)"]
        }
        return args
    }

    @discardableResult
    static func startDaemon(interval: TimeInterval = 0.3, max: Int = 500, ttl: Int = 0) -> Bool {
        guard !isRunning() else { return false }
        guard let exec = currentExecutablePath() else {
            fputs("❌ 无法确定当前可执行文件路径\n", stderr)
            return false
        }

        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logFileURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = recordChildArgs(interval: interval, max: max, ttl: ttl)
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            return true
        } catch {
            fputs("❌ 后台启动失败: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    static func stop() -> Bool {
        guard let pid = readPid() else { return false }
        kill(pid, SIGTERM)
        var alive = waitForExit(pid, tries: 20)
        if alive {
            kill(pid, SIGKILL)
            alive = waitForExit(pid, tries: 20)
        }
        if readPid() == pid {
            removePidFile()
        }
        return !alive
    }

    private static func waitForExit(_ pid: Int32, tries: Int) -> Bool {
        for _ in 0..<tries {
            if kill(pid, 0) != 0 { return false }
            usleep(50_000)
        }
        return true
    }

    // MARK: - LaunchAgent 自启

    static func launchAgentPlist(binaryPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>record</string>
                <string>--daemon-child</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logFileURL.path)</string>
            <key>StandardErrorPath</key>
            <string>\(logFileURL.path)</string>
        </dict>
        </plist>
        """
    }

    static func installLaunchAgent(binaryPath: String) -> Bool {
        let plist = launchAgentPlist(binaryPath: binaryPath)
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("❌ plist 写入失败: \(error.localizedDescription)\n", stderr)
            return false
        }
        return bootstrap(load: true)
    }

    static func removeLaunchAgent() -> Bool {
        _ = bootstrap(load: false)
        try? FileManager.default.removeItem(at: launchAgentURL)
        return true
    }

    static func autostartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private static func bootstrap(load: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        if load {
            process.arguments = ["bootstrap", "gui/\(getuid())", launchAgentURL.path]
        } else {
            process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            fputs("❌ launchctl 执行失败: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
