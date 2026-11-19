import AppKit
import AVFoundation
import ScreenCaptureKit

enum ScreenKind: String, CaseIterable, Codable {
    case display, window
}

enum ScreenTarget: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

struct DisplayItem: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let size: CGSize          // points
}

struct WindowItem: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let pid: pid_t
    let frame: CGRect          // points
}

struct DeviceItem: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Enumerates capturable displays, windows, cameras and microphones.
enum SourceCatalog {
    private static let hiddenBundles: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.WindowManager", "com.apple.Spotlight", "com.apple.systemuiserver",
        "com.apple.wallpaper.agent", "com.apple.screencaptureui",
    ]

    static func shareable() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func displays(_ content: SCShareableContent) -> [DisplayItem] {
        content.displays.map { d in
            DisplayItem(id: d.displayID, name: displayName(d.displayID), size: CGSize(width: d.width, height: d.height))
        }
    }

    static func windows(_ content: SCShareableContent) -> [WindowItem] {
        let me = Bundle.main.bundleIdentifier
        return content.windows.compactMap { w -> WindowItem? in
            guard w.isOnScreen, w.windowLayer == 0, w.frame.width >= 160, w.frame.height >= 100,
                  let app = w.owningApplication, app.bundleIdentifier != me,
                  !hiddenBundles.contains(app.bundleIdentifier) else { return nil }
            let title = w.title ?? ""
            return WindowItem(id: w.windowID, title: title.isEmpty ? app.applicationName : title,
                              appName: app.applicationName, pid: app.processID, frame: w.frame)
        }
    }

    static func displayName(_ id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "Display"
    }

    static func cameras() -> [DeviceItem] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { DeviceItem(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [DeviceItem] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices.map { DeviceItem(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultMicrophoneID() -> String? { AVCaptureDevice.default(for: .audio)?.uniqueID }
    static func defaultCameraID() -> String? { AVCaptureDevice.default(for: .video)?.uniqueID }

    /// Small live snapshot used for the source picker.
    static func thumbnail(filter: SCContentFilter, maxWidth: CGFloat) async -> NSImage? {
        let rect = filter.contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let config = SCStreamConfiguration()
        let w = maxWidth * 2
        config.width = Int(w)
        config.height = Int(w * rect.height / rect.width)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    static func appIcon(pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// Current on-screen bounds (points) of a window, without needing a full content refresh.
    static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }
}

enum Permissions {
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestScreen() -> Bool { CGRequestScreenCaptureAccess() }

    static var camera: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func request(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
