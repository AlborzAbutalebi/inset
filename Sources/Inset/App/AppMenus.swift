import AppKit
import UniformTypeIdentifiers

/// The standard macOS menu bar and Dock menu. The shortcuts shown are the global ⌃⌥ hotkeys,
/// so there is one set of keys to learn, and they work whether or not Inset is in front.
@MainActor
final class AppMenus: NSObject, NSMenuItemValidation {
    private var model: AppModel { .shared }
    private static let repo = URL(string: "https://github.com/AlborzAbutalebi/inset")!

    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let window = windowMenu()
        let help = menu("Help", [item("Inset on GitHub", #selector(openHelp))])
        for m in [appMenu(), fileMenu(), editMenu(), viewMenu(), window, help] {
            let holder = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    func makeDockMenu() -> NSMenu {
        let m = menu("", [recordItem(), pauseItem(), .separator()] + modeItems() + [.separator(), previewItem()])
        m.items.forEach { _ = validateMenuItem($0) }
        return m
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        return menu("Inset", [
            item("About Inset", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), system: true),
            .separator(),
            item("Settings…", #selector(openSettings), key: ","),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Inset", #selector(NSApplication.hide(_:)), key: "h", system: true),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option], system: true),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), system: true),
            .separator(),
            item("Quit Inset", #selector(NSApplication.terminate(_:)), key: "q", system: true),
        ])
    }

    private func fileMenu() -> NSMenu {
        menu("File", [
            recordItem(),
            pauseItem(),
            .separator(),
            item("Open Recording…", #selector(openRecording), key: "o"),
            item("Show Recordings in Finder", #selector(showRecordings), key: "o", mods: [.command, .shift]),
            item("Change Recordings Folder…", #selector(chooseFolder)),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), key: "w", system: true),
        ])
    }

    /// Needed so ⌘C/⌘V/⌘A work in text fields such as the Save dialog's name field.
    private func editMenu() -> NSMenu {
        menu("Edit", [
            item("Undo", Selector(("undo:")), key: "z", system: true),
            item("Redo", Selector(("redo:")), key: "z", mods: [.command, .shift], system: true),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), key: "x", system: true),
            item("Copy", #selector(NSText.copy(_:)), key: "c", system: true),
            item("Paste", #selector(NSText.paste(_:)), key: "v", system: true),
            item("Select All", #selector(NSText.selectAll(_:)), key: "a", system: true),
        ])
    }

    private func viewMenu() -> NSMenu {
        menu("View", [previewItem(), item("Keep Preview on Top", #selector(togglePreviewOnTop)), .separator()]
            + modeItems()
            + [item("Swap Screen and Camera", #selector(swapMode), key: "s", mods: [.control, .option])])
    }

    private func windowMenu() -> NSMenu {
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", system: true),
            item("Zoom", #selector(NSWindow.performZoom(_:)), system: true),
            .separator(),
            item("Inset", #selector(showPanel), key: "0"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), system: true),
        ])
    }

    private func recordItem() -> NSMenuItem {
        item("Start Recording", #selector(toggleRecording), key: "r", mods: [.control, .option])
    }

    private func pauseItem() -> NSMenuItem {
        item("Pause", #selector(togglePause), key: "p", mods: [.control, .option])
    }

    private func previewItem() -> NSMenuItem {
        item("Show Preview", #selector(togglePreview), key: "v", mods: [.control, .option])
    }

    private func modeItems() -> [NSMenuItem] {
        LayoutMode.allCases.enumerated().map { i, m in
            let it = item(m.title, #selector(setMode(_:)), key: "\(m.hotkeyNumber)", mods: [.control, .option])
            it.tag = i
            return it
        }
    }

    // MARK: Builders

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        return m
    }

    /// `system` items have no target, so AppKit sends them up the responder chain (Copy, Close, Hide…).
    private func item(_ title: String, _ action: Selector, key: String = "",
                      mods: NSEvent.ModifierFlags = .command, system: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = system ? nil : self
        return it
    }

    // MARK: Actions

    @objc private func toggleRecording() { model.toggleRecording() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func togglePreview() { model.previewVisible.toggle() }
    @objc private func togglePreviewOnTop() { model.previewOnTop.toggle() }
    @objc private func swapMode() { model.swapMode() }
    @objc private func setMode(_ sender: NSMenuItem) { model.setMode(LayoutMode.allCases[sender.tag]) }
    @objc private func showRecordings() { model.openFolder() }
    @objc private func chooseFolder() { model.chooseFolder() }
    @objc private func showPanel() { WindowManager.shared.showPanel() }
    @objc private func openHelp() { NSWorkspace.shared.open(Self.repo) }

    @objc private func openSettings() {
        WindowManager.shared.showPanel()
        model.settingsShown = true
    }

    /// Reopen a past recording in the export window, e.g. to send it to the iPhone later.
    @objc private func openRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.saveFolder
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { WindowManager.shared.showExport($0) }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleRecording):
            item.title = model.isRecording ? "Stop Recording" : "Start Recording"
            return !model.isStarting && !model.isFinishing
        case #selector(togglePause):
            item.title = model.isPaused ? "Resume" : "Pause"
            return model.isRecording
        case #selector(togglePreview):
            item.title = model.previewVisible ? "Hide Preview" : "Show Preview"
        case #selector(togglePreviewOnTop):
            item.state = model.previewOnTop ? .on : .off
        case #selector(setMode(_:)):
            item.state = LayoutMode.allCases[item.tag] == model.mode ? .on : .off
        default:
            break
        }
        return true
    }
}
