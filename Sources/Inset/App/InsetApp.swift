import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            SelfTest.run(outputDirectory: URL(fileURLWithPath: dir, isDirectory: true))
            return
        }
        InsetApp.main()
    }
}

struct InsetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

struct MenuBarLabel: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.isRecording {
            HStack(spacing: 4) {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                Text(RecordButton.format(model.elapsed)).monospacedDigit()
            }
        } else {
            Image(systemName: "rectangle.inset.bottomright.filled")
        }
    }
}

struct MenuBarContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(model.isRecording ? "Stop Recording   ⌃⌥R" : "Start Recording   ⌃⌥R") { model.toggleRecording() }
        if model.isRecording {
            Button(model.isPaused ? "Resume   ⌃⌥P" : "Pause   ⌃⌥P") { model.togglePause() }
        }
        Divider()
        ForEach(LayoutMode.allCases) { m in
            Button {
                model.setMode(m)
            } label: {
                if model.mode == m {
                    Label("\(m.title)   ⌃⌥\(m.hotkeyNumber)", systemImage: "checkmark")
                } else {
                    Text("\(m.title)   ⌃⌥\(m.hotkeyNumber)")
                }
            }
        }
        Divider()
        Button(model.previewVisible ? "Hide Preview   ⌃⌥V" : "Show Preview   ⌃⌥V") { model.previewVisible.toggle() }
        Button("Show Inset") { WindowManager.shared.showPanel() }
        Button("Recordings") { model.openFolder() }
        Divider()
        Button("Quit Inset") { NSApp.terminate(nil) }
    }
}
