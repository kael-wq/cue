import AppKit
import Foundation

/// 剪贴板监控：轮询 NSPasteboard.general.changeCount
final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let interval: TimeInterval

    var onChange: ((ClipboardEvent) -> Void)?

    init(interval: TimeInterval = 0.3) {
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        if let t = timer {
            RunLoop.current.add(t, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let types = pasteboard.types ?? []
        let app = FrontAppDetector.current()

        let event = ClipboardEvent(
            timestamp: Date(),
            changeCount: currentCount,
            types: types.map { $0.rawValue },
            isText: types.contains(.string),
            isImage: types.contains(.tiff) || types.contains(.png),
            isFileURL: types.contains(.fileURL),
            appName: app.name,
            bundleId: app.bundleId,
            pid: app.pid
        )
        onChange?(event)
    }
}

// MARK: - 数据模型

struct ClipboardEvent {
    let timestamp: Date
    let changeCount: Int
    let types: [String]
    let isText: Bool
    let isImage: Bool
    let isFileURL: Bool
    let appName: String
    let bundleId: String
    let pid: Int32
}

struct AppInfo {
    let name: String
    let bundleId: String
    let pid: Int32
}
