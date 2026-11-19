import AppKit
import SwiftUI

enum Theme {
    static let violet = Color(red: 0.49, green: 0.40, blue: 1.0)
    static let cyan = Color(red: 0.28, green: 0.78, blue: 1.0)
    static let accent = LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.30)
    static let recordGradient = LinearGradient(colors: [Color(red: 1.0, green: 0.38, blue: 0.36), Color(red: 0.92, green: 0.16, blue: 0.30)],
                                               startPoint: .top, endPoint: .bottom)
    static let screenLayer = LinearGradient(colors: [Color(red: 0.25, green: 0.30, blue: 0.80), Color(red: 0.46, green: 0.34, blue: 0.96)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cameraLayer = LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.36), Color(red: 0.96, green: 0.30, blue: 0.52)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.075)
    static let dim = Color.white.opacity(0.55)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Rounded translucent container used for every section of the panel.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A circular icon button that lights up with the accent gradient when on.
struct IconToggle: View {
    let on: String
    var off: String?
    @Binding var isOn: Bool
    var help: String
    var size: CGFloat = 28

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } } label: {
            Image(systemName: isOn ? on : (off ?? on))
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Theme.dim)
                .frame(width: size, height: size)
                .background(Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.07))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String
    var size: CGFloat = 32
    var action: () -> Void

    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Segmented control of icons with a sliding accent pill.
struct IconSegments<T: Hashable>: View {
    let items: [(value: T, symbol: String, help: String)]
    @Binding var selection: T
    var width: CGFloat = 34
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let selected = item.value == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = item.value } } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .white : Theme.dim)
                        .frame(width: width, height: 24)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// Text segmented control in the same style, for the settings popover.
struct TextSegments<T: Hashable>: View {
    let items: [(value: T, label: String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let selected = item.value == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = item.value } } label: {
                    Text(item.label)
                        .font(Theme.rounded(11, .semibold))
                        .foregroundStyle(selected ? .white : Theme.dim)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(level, 0.000_01))
            let v = CGFloat(min(max((db + 50) / 50, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.3, green: 0.9, blue: 0.6), Color(red: 0.95, green: 0.85, blue: 0.3), Theme.record],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * v))
                    .animation(.linear(duration: 0.08), value: v)
            }
        }
        .frame(height: 5)
    }
}

/// Miniature drawing of a layout mode, used for the mode buttons.
struct ModeGlyph: View {
    let mode: LayoutMode
    var shape: CameraShape = .circle

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let fullIsScreen = mode == .screen || mode == .screenWithCamera
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .fill(fullIsScreen ? Theme.screenLayer : Theme.cameraLayer)
                    .overlay(
                        Image(systemName: fullIsScreen ? "display" : "person.fill")
                            .font(.system(size: h * 0.30, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .offset(x: mode.hasOverlay ? -w * 0.1 : 0, y: mode.hasOverlay ? -h * 0.08 : 0)
                    )
                if mode == .screenWithCamera {
                    overlayCamera(size: h * 0.46)
                        .padding(h * 0.08)
                } else if mode == .cameraWithScreen {
                    RoundedRectangle(cornerRadius: h * 0.07, style: .continuous)
                        .fill(Theme.screenLayer)
                        .overlay(Image(systemName: "display").font(.system(size: h * 0.16, weight: .bold)).foregroundStyle(.white))
                        .overlay(RoundedRectangle(cornerRadius: h * 0.07, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 1))
                        .frame(width: w * 0.42, height: w * 0.42 * 0.62)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(h * 0.08)
                }
            }
        }
    }

    @ViewBuilder private func overlayCamera(size: CGFloat) -> some View {
        let body = Image(systemName: "person.fill")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
        switch shape {
        case .circle:
            Circle().fill(Theme.cameraLayer).overlay(body)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        case .square, .rectangle:
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Theme.cameraLayer).overlay(body)
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .frame(width: shape == .rectangle ? size * 1.4 : size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
    }
}

extension View {
    func keycap(_ text: String) -> some View {
        overlay(alignment: .topLeading) {
            Text(text)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 13, height: 13)
                .background(Circle().fill(.black.opacity(0.35)))
                .padding(4)
        }
    }
}
