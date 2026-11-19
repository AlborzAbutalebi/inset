import AppKit

@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            SelfTest.run(outputDirectory: URL(fileURLWithPath: dir, isDirectory: true))
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

/// A regular Dock app: one main window plus the standard menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menus = AppMenus()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere") // no windows go full screen
        NSApp.mainMenu = menus.makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        WindowManager.shared.showPanel()
        model.bootstrap()
        HotKeys.shared.install(model)
        Snapshot.scheduleIfRequested()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showPanel()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { menus.makeDockMenu() }

    /// Closing the last window quits, like any single-window Mac app, unless a recording is running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.isRecording
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.isRecording else { return .terminateNow }
        Task { @MainActor in
            await model.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
