import AppKit
import SwiftUI

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var panel: NSWindow?
    private var preview: PreviewWindowController?
    private var exports: [NSWindow] = []

    func showPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: ControlPanel(model: AppModel.shared))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Inset"
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.contentView = hosting
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary]
            w.setFrameAutosaveName("InsetPanel")
            if !w.setFrameUsingName("InsetPanel") { w.center() }
            panel = w
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Preview

    func showPreview() {
        let model = AppModel.shared
        if preview == nil {
            let c = PreviewWindowController()
            if let device = model.studio?.renderLoop.compositor.device { c.view.attach(device: device) }
            preview = c
        }
        guard let preview, let w = preview.window else { return }
        preview.setAspect(model.canvasSize)
        updatePreviewLevel()
        w.orderFront(nil)
        preview.updateAttachment()
        model.studio?.refreshScreenFilter()
    }

    func hidePreview() {
        AppModel.shared.studio?.renderLoop.preview = nil
        preview?.window?.orderOut(nil)
    }

    func updatePreviewLevel() {
        preview?.window?.level = AppModel.shared.previewOnTop ? .floating : .normal
    }

    func canvasDidChange(_ canvas: CGSize) {
        guard let preview, preview.window?.isVisible == true else { return }
        preview.setAspect(canvas)
        preview.view.refreshOverlay()
    }

    func layoutDidChange() {
        preview?.view.refreshOverlay()
    }

    // MARK: Export

    func showExport(_ url: URL) {
        let hosting = NSHostingView(rootView: ExportView(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = url.deletingPathExtension().lastPathComponent
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.contentView = hosting
        w.minSize = NSSize(width: 460, height: 400)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        exports.append(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        exports.removeAll { $0 === w }
    }
}
