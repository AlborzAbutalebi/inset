import SwiftUI

/// A live miniature of the canvas. Drag the overlay to move it, drag the dot to resize,
/// double-click to swap — works even with the preview closed.
struct LayoutPad: View {
    @Bindable var model: AppModel
    @State private var dragOrigin: CGRect?
    @State private var resizeAnchor: CGPoint?

    var body: some View {
        let canvas = model.canvasSize
        GeometryReader { g in
            let k = g.size.width / canvas.width
            let snap = model.layoutSnapshot
            let scene = Geometry.target(snap, canvas: canvas, screenAspect: model.screenAspect, cameraAspect: model.cameraAspect)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.55)
                if scene.cameraOnTop {
                    layer(.screen, scene.screen, k: k, canvas: canvas)
                    layer(.camera, scene.camera, k: k, canvas: canvas)
                } else {
                    layer(.camera, scene.camera, k: k, canvas: canvas)
                    layer(.screen, scene.screen, k: k, canvas: canvas)
                }
                if let overlay = overlayLayer {
                    handle(overlay, rect: overlay == .camera ? scene.camera.rect : scene.screen.rect, k: k, canvas: canvas)
                }
            }
            .coordinateSpace(name: "pad")
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        .frame(maxWidth: .infinity, maxHeight: 186)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.mode)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.cameraShape)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: canvas)
    }

    private var overlayLayer: SceneLayer? {
        switch model.mode {
        case .screenWithCamera: .camera
        case .cameraWithScreen: .screen
        default: nil
        }
    }

    @ViewBuilder
    private func content(_ which: SceneLayer) -> some View {
        if which == .screen {
            ZStack {
                Theme.screenLayer
                if let target = model.screenTarget, let img = model.thumbnails[target] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: model.screenKind == .window ? "macwindow" : "display")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
        } else {
            ZStack {
                Theme.cameraLayer
                Image(systemName: model.cameraEnabled ? "person.fill" : "video.slash.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    @ViewBuilder
    private func layer(_ which: SceneLayer, _ s: LayerState, k: CGFloat, canvas: CGSize) -> some View {
        let r = s.rect
        let isOverlay = overlayLayer == which
        let shape = RoundedRectangle(cornerRadius: s.radius * k, style: .circular)
        content(which)
            .frame(width: max(r.width * k, 1), height: max(r.height * k, 1))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(isOverlay ? 0.85 : 0), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.45 * s.shadow), radius: 5, y: 2)
            .opacity(s.opacity)
            .contentShape(shape)
            .gesture(moveGesture(which, rect: r, k: k, canvas: canvas), including: isOverlay ? .all : .none)
            .onTapGesture(count: 2) { if isOverlay { model.swapMode() } }
            .position(x: r.midX * k, y: r.midY * k)
    }

    private func moveGesture(_ which: SceneLayer, rect: CGRect, k: CGFloat, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("pad"))
            .onChanged { v in
                if dragOrigin == nil { dragOrigin = rect }
                guard let o = dragOrigin else { return }
                var r = o.offsetBy(dx: v.translation.width / k, dy: v.translation.height / k)
                r.origin.x = min(max(r.minX, 0), canvas.width - r.width)
                r.origin.y = min(max(r.minY, 0), canvas.height - r.height)
                r = Geometry.snapped(r, canvas: canvas, threshold: 8 / k)
                model.setPlacement(which, Geometry.placement(for: r, canvas: canvas))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func handle(_ which: SceneLayer, rect: CGRect, k: CGFloat, canvas: CGSize) -> some View {
        let corner = Geometry.handleCorner(of: rect, canvas: canvas)
        let aspect = Geometry.overlayAspect(which, model.layoutSnapshot, screenAspect: model.screenAspect, cameraAspect: model.cameraAspect)
        return Circle()
            .fill(.white)
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .contentShape(Circle().inset(by: -7))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
                    .onChanged { v in
                        if resizeAnchor == nil { resizeAnchor = corner.anchor }
                        guard let anchor = resizeAnchor else { return }
                        let p = CGPoint(x: v.location.x / k, y: v.location.y / k)
                        let r = Geometry.resized(rect, anchor: anchor, to: p, aspect: aspect, canvas: canvas)
                        model.setPlacement(which, Geometry.placement(for: r, canvas: canvas))
                    }
                    .onEnded { _ in resizeAnchor = nil }
            )
            .position(x: corner.handle.x * k, y: corner.handle.y * k)
            .help("Drag to resize")
    }
}
