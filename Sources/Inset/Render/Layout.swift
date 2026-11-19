import CoreGraphics
import Foundation

/// The four scene arrangements Inset can switch between live.
enum LayoutMode: Int, CaseIterable, Codable, Identifiable {
    case screen = 0
    case camera
    case screenWithCamera
    case cameraWithScreen

    var id: Int { rawValue }
    var hotkeyNumber: Int { rawValue + 1 }
    var hasOverlay: Bool { self == .screenWithCamera || self == .cameraWithScreen }

    var title: String {
        switch self {
        case .screen: "Screen"
        case .camera: "Camera"
        case .screenWithCamera: "Screen + Camera"
        case .cameraWithScreen: "Camera + Screen"
        }
    }

    /// The opposite picture-in-picture arrangement (used by "swap").
    var swapped: LayoutMode {
        switch self {
        case .screen: .camera
        case .camera: .screen
        case .screenWithCamera: .cameraWithScreen
        case .cameraWithScreen: .screenWithCamera
        }
    }
}

enum SceneLayer { case screen, camera }

enum CameraShape: String, CaseIterable, Codable {
    case rectangle, square, circle
}

enum ScreenFit: String, CaseIterable, Codable {
    case fit, fill
}

/// Normalised overlay placement: centre in canvas units (0…1) and width as a fraction of canvas width.
struct Placement: Codable, Equatable {
    var cx: Double
    var cy: Double
    var width: Double
}

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let canvas = RGBA(r: 0.055, g: 0.055, b: 0.065)
}

/// Everything the compositor needs to know about how to arrange the scene.
struct LayoutSnapshot: Equatable {
    var mode: LayoutMode = .screenWithCamera
    var cameraPlacement = Placement(cx: 0.88, cy: 0.80, width: 0.17)
    var screenPlacement = Placement(cx: 0.80, cy: 0.79, width: 0.32)
    var cameraShape: CameraShape = .circle
    var roundness: Double = 0.22          // 0…0.5 of the overlay's short side
    var mirrorCamera = true
    var screenFit: ScreenFit = .fit
    var border = false
    var shadow = true
    var transitionDuration: Double = 0.42
    var background = RGBA.canvas
}

/// The visual state of one layer for one frame, in canvas pixels (origin top-left).
struct LayerState: Equatable {
    var rect: CGRect
    var radius: CGFloat
    var opacity: CGFloat
    var shadow: CGFloat
    var border: CGFloat

    static func lerp(_ a: LayerState, _ b: LayerState, _ t: CGFloat) -> LayerState {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return LayerState(
            rect: CGRect(x: m(a.rect.minX, b.rect.minX), y: m(a.rect.minY, b.rect.minY),
                         width: m(a.rect.width, b.rect.width), height: m(a.rect.height, b.rect.height)),
            radius: m(a.radius, b.radius),
            opacity: m(a.opacity, b.opacity),
            shadow: m(a.shadow, b.shadow),
            border: m(a.border, b.border))
    }
}

struct SceneState: Equatable {
    var screen: LayerState
    var camera: LayerState
    var cameraOnTop: Bool

    static func lerp(_ a: SceneState, _ b: SceneState, _ t: CGFloat) -> SceneState {
        SceneState(screen: .lerp(a.screen, b.screen, t),
                   camera: .lerp(a.camera, b.camera, t),
                   cameraOnTop: b.cameraOnTop)
    }
}

/// Pure layout maths shared by the compositor, the preview window and the layout pad.
enum Geometry {
    static let minOverlayWidth = 0.08
    static let maxOverlayWidth = 0.85

    static func edgeMargin(_ canvas: CGSize) -> CGFloat { min(canvas.width, canvas.height) * 0.03 }

    static func cameraOverlayAspect(_ shape: CameraShape, cameraAspect: CGFloat) -> CGFloat {
        shape == .rectangle ? cameraAspect : 1
    }

    static func overlayAspect(_ layer: SceneLayer, _ s: LayoutSnapshot, screenAspect: CGFloat, cameraAspect: CGFloat) -> CGFloat {
        layer == .camera ? cameraOverlayAspect(s.cameraShape, cameraAspect: cameraAspect) : screenAspect
    }

    static func overlayRect(_ p: Placement, aspect: CGFloat, canvas: CGSize) -> CGRect {
        let aspect = max(aspect, 0.1)
        var w = CGFloat(p.width) * canvas.width
        var h = w / aspect
        if h > canvas.height * 0.92 { h = canvas.height * 0.92; w = h * aspect }
        var x = CGFloat(p.cx) * canvas.width - w / 2
        var y = CGFloat(p.cy) * canvas.height - h / 2
        x = min(max(x, 0), canvas.width - w)
        y = min(max(y, 0), canvas.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func placement(for rect: CGRect, canvas: CGSize) -> Placement {
        Placement(cx: Double(rect.midX / canvas.width),
                  cy: Double(rect.midY / canvas.height),
                  width: Double(rect.width / canvas.width))
    }

    static func fit(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        let a = max(aspect, 0.01)
        if bounds.width / bounds.height > a {
            let w = bounds.height * a
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        } else {
            let h = bounds.width / a
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }

    static func overlayRadius(_ layer: SceneLayer, rect: CGRect, _ s: LayoutSnapshot) -> CGFloat {
        let short = min(rect.width, rect.height)
        if layer == .camera {
            return s.cameraShape == .circle ? short / 2 : CGFloat(s.roundness) * short
        }
        return CGFloat(min(s.roundness, 0.5)) * 0.35 * short
    }

    /// The resting (non-animated) state of the scene for a layout.
    static func target(_ s: LayoutSnapshot, canvas: CGSize, screenAspect: CGFloat, cameraAspect: CGFloat) -> SceneState {
        let full = CGRect(origin: .zero, size: canvas)
        let screenFull = s.screenFit == .fit ? fit(aspect: screenAspect, in: full) : full

        let camRect = overlayRect(s.cameraPlacement, aspect: cameraOverlayAspect(s.cameraShape, cameraAspect: cameraAspect), canvas: canvas)
        let scrRect = overlayRect(s.screenPlacement, aspect: screenAspect, canvas: canvas)
        let shadow: CGFloat = s.shadow ? 1 : 0
        let border: CGFloat = s.border ? 1 : 0

        let screenFullState = LayerState(rect: screenFull, radius: 0, opacity: 1, shadow: 0, border: 0)
        let cameraFullState = LayerState(rect: full, radius: 0, opacity: 1, shadow: 0, border: 0)
        let camOverlay = LayerState(rect: camRect, radius: overlayRadius(.camera, rect: camRect, s), opacity: 1, shadow: shadow, border: border)
        let scrOverlay = LayerState(rect: scrRect, radius: overlayRadius(.screen, rect: scrRect, s), opacity: 1, shadow: shadow, border: border)

        func hidden(_ l: LayerState) -> LayerState {
            var h = l
            h.rect = l.rect.insetBy(dx: l.rect.width * 0.06, dy: l.rect.height * 0.06)
            h.radius *= 0.88
            h.opacity = 0
            h.shadow = 0
            return h
        }

        switch s.mode {
        case .screen:
            return SceneState(screen: screenFullState, camera: hidden(camOverlay), cameraOnTop: true)
        case .camera:
            return SceneState(screen: hidden(scrOverlay), camera: cameraFullState, cameraOnTop: false)
        case .screenWithCamera:
            return SceneState(screen: screenFullState, camera: camOverlay, cameraOnTop: true)
        case .cameraWithScreen:
            return SceneState(screen: scrOverlay, camera: cameraFullState, cameraOnTop: false)
        }
    }

    /// Snaps an overlay rect to the canvas margins / centre lines when it is close to them.
    static func snapped(_ r: CGRect, canvas: CGSize, threshold: CGFloat) -> CGRect {
        let m = edgeMargin(canvas)
        var out = r
        let xs: [CGFloat] = [m, canvas.width - m - r.width, (canvas.width - r.width) / 2]
        let ys: [CGFloat] = [m, canvas.height - m - r.height, (canvas.height - r.height) / 2]
        if let x = xs.min(by: { abs($0 - r.minX) < abs($1 - r.minX) }), abs(x - r.minX) < threshold { out.origin.x = x }
        if let y = ys.min(by: { abs($0 - r.minY) < abs($1 - r.minY) }), abs(y - r.minY) < threshold { out.origin.y = y }
        return out
    }

    /// Resizes `r` keeping `aspect`, anchored at the corner opposite to the dragged one.
    static func resized(_ r: CGRect, anchor: CGPoint, to point: CGPoint, aspect: CGFloat, canvas: CGSize) -> CGRect {
        let dx = abs(point.x - anchor.x)
        let dy = abs(point.y - anchor.y)
        var w = max(dx, dy * aspect)
        w = min(max(w, canvas.width * CGFloat(minOverlayWidth)), canvas.width * CGFloat(maxOverlayWidth))
        var h = w / aspect
        if h > canvas.height * 0.92 { h = canvas.height * 0.92; w = h * aspect }
        let x = point.x < anchor.x ? anchor.x - w : anchor.x
        let y = point.y < anchor.y ? anchor.y - h : anchor.y
        var out = CGRect(x: x, y: y, width: w, height: h)
        out.origin.x = min(max(out.minX, 0), canvas.width - w)
        out.origin.y = min(max(out.minY, 0), canvas.height - h)
        return out
    }

    /// The corner of `r` closest to the canvas centre — where the resize handle lives.
    static func handleCorner(of r: CGRect, canvas: CGSize) -> (handle: CGPoint, anchor: CGPoint) {
        let left = r.midX > canvas.width / 2
        let top = r.midY > canvas.height / 2
        let hx = left ? r.minX : r.maxX
        let hy = top ? r.minY : r.maxY
        let ax = left ? r.maxX : r.minX
        let ay = top ? r.maxY : r.minY
        return (CGPoint(x: hx, y: hy), CGPoint(x: ax, y: ay))
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: CGFloat(max(2, Int(s.width.rounded()) & ~1)),
               height: CGFloat(max(2, Int(s.height.rounded()) & ~1)))
    }
}

/// Animates between layout targets so every switch glides instead of cutting.
final class SceneAnimator {
    private var from: SceneState?
    private var start: Double = 0
    private var duration: Double = 0
    private var lastMode: LayoutMode?
    private var lastShape: CameraShape?
    private var current: SceneState?

    func state(target: SceneState, layout: LayoutSnapshot, now: Double) -> SceneState {
        let changed = (lastMode != nil && lastMode != layout.mode) || (lastShape != nil && lastShape != layout.cameraShape)
        if changed, let cur = current, layout.transitionDuration > 0 {
            from = cur
            start = now
            duration = layout.transitionDuration
        }
        lastMode = layout.mode
        lastShape = layout.cameraShape

        var result = target
        if let f = from {
            let t = (now - start) / max(duration, 0.001)
            if t >= 1 {
                from = nil
            } else {
                result = SceneState.lerp(f, target, CGFloat(Self.ease(t)))
            }
        }
        current = result
        return result
    }

    var isAnimating: Bool { from != nil }

    /// Smooth ease-in-out with a gentle, natural settle.
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
