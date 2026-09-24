import AppKit

/// 前台应用检测
struct FrontAppDetector {
    static func current() -> AppInfo {
        if let front = NSWorkspace.shared.frontmostApplication {
            return AppInfo(
                name: front.localizedName ?? "unknown",
                bundleId: front.bundleIdentifier ?? "unknown",
                pid: front.processIdentifier
            )
        }
        for app in NSWorkspace.shared.runningApplications where app.isActive {
            return AppInfo(
                name: app.localizedName ?? "unknown",
                bundleId: app.bundleIdentifier ?? "unknown",
                pid: app.processIdentifier
            )
        }
        return AppInfo(name: "unknown", bundleId: "unknown", pid: -1)
    }
}
