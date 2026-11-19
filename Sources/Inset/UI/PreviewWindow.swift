import AppKit
import QuartzCore
import SwiftUI

/// Live preview of the exact recorded output. Inset's own windows are excluded from capture,
/// so this never shows up in a recording. Drag the overlay to move it, drag its corner to
/// resize, pinch/scroll to scale, double-click to swap.
final class PreviewView: NSView {
    let metalLayer = CAMetalLayer()
    private let guides = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private var hud: NSHostingView<PreviewHUD>?
    private var tracking: NSTrackingArea?
    private var hovering = false

    private enum Drag {
        case none
        case move(layer: SceneLayer, origin: CGRect, start: CGPoint)
        case resize(layer: SceneLayer, anchor: CGPoint)
        case window
    }
    private var drag: Drag = .none

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(metalLayer)

        guides.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        guides.fillColor = nil
        guides.lineWidth = 1.5
        guides.opacity = 0
        layer?.addSublayer(guides)

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.shadowColor = NSColor.black.cgColor
        handleLayer.shadowOpacity = 0.5
        handleLayer.shadowRadius = 2
        handleLayer.shadowOffset = CGSize(width: 0, height: -1)
        handleLayer.opacity = 0
        layer?.addSublayer(handleLayer)

        let hud = NSHostingView(rootView: PreviewHUD(model: AppModel.shared))
        hud.alphaValue = 0
        addSubview(hud)
        self.hud = hud
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(device: MTLDevice) { metalLayer.device = device }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guides.frame = bounds
        handleLayer.frame = bounds
        CATransaction.commit()
        if let hud {
            let size = hud.fittingSize
            hud.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12, width: size.width, height: size.height)
        }
        refreshOverlay()
        AppModel.shared.studio?.renderLoop.invalidatePreview()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Geometry

    private var model: AppModel { AppModel.shared }

    /// canvas pixels → view points
    private var mapping: (scale: CGFloat, offset: CGPoint) {
        let c = model.canvasSize
        let s = min(bounds.width / c.width, bounds.height / c.height)
        return (s, CGPoint(x: (bounds.width - c.width * s) / 2, y: (bounds.height - c.height * s) / 2))
    }

    private func toCanvas(_ p: CGPoint) -> CGPoint {
        let m = mapping
        return CGPoint(x: (p.x - m.offset.x) / m.scale, y: (p.y - m.offset.y) / m.scale)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let m = mapping
        return CGRect(x: r.minX * m.scale + m.offset.x, y: r.minY * m.scale + m.offset.y, width: r.width * m.scale, height: r.height * m.scale)
    }

    private var overlay: (layer: SceneLayer, rect: CGRect, radius: CGFloat)? {
        let mode = model.mode
        guard mode.hasOverlay else { return nil }
        let scene = Geometry.target(model.layoutSnapshot, canvas: model.canvasSize, screenAspect: model.screenAspect, cameraAspect: model.cameraAspect)
        return mode == .screenWithCamera ? (.camera, scene.camera.rect, scene.camera.radius) : (.screen, scene.screen.rect, scene.screen.radius)
    }

    func refreshOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let o = overlay else {
            guides.path = nil
            handleLayer.path = nil
            return
        }
        let r = toView(o.rect)
        let radius = o.radius * mapping.scale
        guides.path = CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
        let h = toView(CGRect(origin: Geometry.handleCorner(of: o.rect, canvas: model.canvasSize).handle, size: .zero)).origin
        handleLayer.path = CGPath(ellipseIn: CGRect(x: h.x - 6, y: h.y - 6, width: 12, height: 12), transform: nil)
    }

    private func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        guides.opacity = on ? 1 : 0
        handleLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            hud?.animator().alphaValue = on ? 1 : 0
        }
    }

    // MARK: Mouse

    private enum Hit { case handle, overlay, background }

    private func hitTestOverlay(_ viewPoint: CGPoint) -> Hit {
        guard let o = overlay else { return .background }
        let handle = toView(CGRect(origin: Geometry.handleCorner(of: o.rect, canvas: model.canvasSize).handle, size: .zero)).origin
        if hypot(viewPoint.x - handle.x, viewPoint.y - handle.y) < 12 { return .handle }
        if toView(o.rect).contains(viewPoint) { return .overlay }
        return .background
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false); NSCursor.arrow.set() }

    override func mouseMoved(with event: NSEvent) {
        setHover(true)
        let p = convert(event.locationInWindow, from: nil)
        switch hitTestOverlay(p) {
        case .handle: NSCursor.crosshair.set()
        case .overlay: NSCursor.openHand.set()
        case .background: NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let o = overlay else { drag = .window; window?.performDrag(with: event); return }
        if event.clickCount == 2, hitTestOverlay(p) == .overlay {
            model.swapMode()
            return
        }
        switch hitTestOverlay(p) {
        case .handle:
            drag = .resize(layer: o.layer, anchor: Geometry.handleCorner(of: o.rect, canvas: model.canvasSize).anchor)
        case .overlay:
            drag = .move(layer: o.layer, origin: o.rect, start: toCanvas(p))
            NSCursor.closedHand.set()
        case .background:
            drag = .window
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toCanvas(convert(event.locationInWindow, from: nil))
        let canvas = model.canvasSize
        switch drag {
        case .move(let layer, let origin, let start):
            var r = origin.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), canvas.width - r.width)
            r.origin.y = min(max(r.minY, 0), canvas.height - r.height)
            r = Geometry.snapped(r, canvas: canvas, threshold: 10 / mapping.scale)
            model.setPlacement(layer, Geometry.placement(for: r, canvas: canvas))
        case .resize(let layer, let anchor):
            let aspect = Geometry.overlayAspect(layer, model.layoutSnapshot, screenAspect: model.screenAspect, cameraAspect: model.cameraAspect)
            let r = Geometry.resized(.zero, anchor: anchor, to: p, aspect: aspect, canvas: canvas)
            model.setPlacement(layer, Geometry.placement(for: r, canvas: canvas))
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.openHand.set() }
        drag = .none
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard hitTestOverlay(p) != .background else { return }
        scaleOverlay(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04))
    }

    override func magnify(with event: NSEvent) {
        scaleOverlay(by: 1 + event.magnification)
    }

    private func scaleOverlay(by factor: CGFloat) {
        guard let o = overlay else { return }
        var p = model.placement(o.layer)
        p.width = min(max(p.width * Double(factor), Geometry.minOverlayWidth), Geometry.maxOverlayWidth)
        model.setPlacement(o.layer, p)
    }
}

/// Hover toolbar inside the preview: switch modes, record, pin.
struct PreviewHUD: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LayoutMode.allCases) { m in
                Button { model.setMode(m) } label: {
                    ModeGlyph(mode: m, shape: model.cameraShape)
                        .frame(width: 34, height: 22)
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(model.mode == m ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), lineWidth: 1.5))
                        .opacity(model.mode == m ? 1 : 0.65)
                }
                .buttonStyle(.plain)
                .help(model.mode == m ? m.title : "\(m.title)   ⌃⌥\(m.hotkeyNumber)")
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            Button { model.toggleRecording() } label: {
                ZStack {
                    Circle().fill(Theme.recordGradient).frame(width: 24, height: 24)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(.white).frame(width: 8, height: 8)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Record   ⌃⌥R")
            Button { model.previewOnTop.toggle() } label: {
                Image(systemName: model.previewOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.previewOnTop ? .white : Theme.dim)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Keep on top")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .environment(\.colorScheme, .dark)
    }
}

final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    let view = PreviewView(frame: NSRect(x: 0, y: 0, width: 560, height: 315))

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 315),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Preview"
        w.backgroundColor = .black
        w.isMovableByWindowBackground = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.minSize = NSSize(width: 260, height: 150)
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("InsetPreview")
        super.init(window: w)
        w.delegate = self
        if !w.setFrameUsingName("InsetPreview") { w.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAspect(_ canvas: CGSize) {
        guard let w = window, canvas.width > 0, canvas.height > 0 else { return }
        w.contentAspectRatio = canvas
        let frame = w.frame
        let contentWidth = w.contentRect(forFrameRect: frame).width
        let newContent = NSSize(width: contentWidth, height: (contentWidth * canvas.height / canvas.width).rounded())
        var newFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: newContent))
        newFrame.origin = CGPoint(x: frame.minX, y: frame.maxY - newFrame.height)
        if abs(newFrame.height - frame.height) > 1 { w.setFrame(newFrame, display: true, animate: w.isVisible) }
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.studio?.renderLoop.preview = nil
        if AppModel.shared.previewVisible { AppModel.shared.previewVisible = false }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateAttachment() }
    func windowDidMiniaturize(_ notification: Notification) { updateAttachment() }
    func windowDidDeminiaturize(_ notification: Notification) { updateAttachment() }

    /// Only render the preview while it can actually be seen.
    func updateAttachment() {
        guard let w = window, let loop = AppModel.shared.studio?.renderLoop else { return }
        let visible = w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        loop.preview = visible ? view.metalLayer : nil
        if visible { loop.invalidatePreview() }
    }
}
