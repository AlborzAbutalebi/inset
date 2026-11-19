import AVFoundation
import SwiftUI

struct ControlPanel: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 12) {
            header
            ModeBar(model: model)
            LayoutPad(model: model)
            StyleRow(model: model)
            SourceCard(model: model)
            DeviceCard(model: model)
            RecordBar(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(width: 384)
        .ignoresSafeArea(edges: .top)
        .background(VisualEffect(material: .hudWindow).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(Theme.rounded(12, .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: model.toast)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 58)
            Circle().fill(Theme.accent).frame(width: 9, height: 9)
            Text("Inset").font(Theme.rounded(13, .semibold))
            Spacer()
            if model.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(Theme.record).frame(width: 7, height: 7)
                    Text(model.isPaused ? "Paused" : "REC").font(Theme.rounded(10, .bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .transition(.opacity)
            }
            Button { showSettings.toggle() } label: {
                HStack(spacing: 4) {
                    Text("\(model.resolution.label) · \(model.fps)")
                    Image(systemName: "slider.horizontal.3")
                }
                .font(Theme.rounded(11, .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Output")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { OutputSettings(model: model) }
        }
        .frame(height: 22)
    }
}

struct ModeBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LayoutMode.allCases) { m in
                let selected = model.mode == m
                Button { model.setMode(m) } label: {
                    ModeGlyph(mode: m, shape: model.cameraShape)
                        .frame(height: 48)
                        .keycap("\(m.hotkeyNumber)")
                        .padding(3)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.06)), lineWidth: selected ? 2 : 1)
                        )
                        .opacity(selected ? 1 : 0.62)
                        .scaleEffect(selected ? 1 : 0.97)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(m.title)   ⌃⌥\(m.hotkeyNumber)")
            }
        }
        .animation(.snappy(duration: 0.25), value: model.mode)
    }
}

struct StyleRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            IconSegments(items: [
                (CameraShape.rectangle, "rectangle.fill", "Rectangle camera"),
                (CameraShape.square, "square.fill", "Square camera"),
                (CameraShape.circle, "circle.fill", "Circle camera"),
            ], selection: $model.cameraShape, width: 28)
            Slider(value: $model.roundness, in: 0...0.5)
                .controlSize(.mini)
                .frame(width: 64)
                .tint(Theme.violet)
                .help("Corner radius")
            Spacer(minLength: 0)
            IconToggle(on: "square.filled.on.square", isOn: $model.shadow, help: "Shadow", size: 26)
            IconToggle(on: "circle.dashed.inset.filled", isOn: $model.border, help: "Border", size: 26)
            IconToggle(on: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill", isOn: $model.mirrorCamera, help: "Mirror camera", size: 26)
            IconToggle(on: "sparkles", isOn: $model.smoothTransitions, help: "Smooth transitions", size: 26)
        }
    }
}

struct SourceCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconSegments(items: [
                        (ScreenKind.display, "display", "Record a display"),
                        (ScreenKind.window, "macwindow", "Record a window"),
                    ], selection: $model.screenKind, width: 40)
                    Spacer()
                    IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 24) {
                        Task { await model.refreshScreens() }
                    }
                }
                if model.screenPermission {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            if model.screenKind == .display {
                                ForEach(model.displays) { d in
                                    SourceThumb(image: model.thumbnails[.display(d.id)], icon: nil, symbol: "display",
                                                caption: d.name, selected: model.screenTarget == .display(d.id)) {
                                        model.selectedDisplayID = d.id
                                    }
                                }
                            } else {
                                ForEach(model.windows) { w in
                                    SourceThumb(image: model.thumbnails[.window(w.id)], icon: SourceCatalog.appIcon(pid: w.pid),
                                                symbol: "macwindow", caption: w.title, selected: model.selectedWindowID == w.id) {
                                        model.selectedWindowID = w.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                    }
                    .frame(height: 88)
                } else {
                    ScreenPermissionPrompt(model: model)
                }
            }
        }
    }
}

struct SourceThumb: View {
    let image: NSImage?
    let icon: NSImage?
    let symbol: String
    let caption: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.06)
                                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                    .frame(width: 100, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22).offset(x: 5, y: 5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(hover ? 0.3 : 0.0)), lineWidth: 2)
                        .padding(-3)
                )
                Text(caption)
                    .font(Theme.rounded(10, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : Theme.dim)
                    .lineLimit(1)
                    .frame(width: 100)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(caption)
    }
}

struct ScreenPermissionPrompt: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Button { model.requestScreen() } label: {
                    Text("Allow Screen Recording")
                        .font(Theme.rounded(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                if model.screenPermissionRequested {
                    Button("Relaunch Inset") { model.relaunch() }
                        .buttonStyle(.link)
                        .font(Theme.rounded(11))
                }
            }
            Spacer()
        }
        .frame(height: 70)
    }
}

struct DeviceCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card {
            VStack(spacing: 10) {
                DeviceRow(on: "video.fill", off: "video.slash.fill", help: "Camera", isOn: $model.cameraEnabled,
                          permission: model.cameraPermission, request: { await model.requestCamera() }) {
                    Picker("", selection: Binding(get: { model.resolvedCameraID }, set: { model.cameraID = $0 })) {
                        ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }
                DeviceRow(on: "mic.fill", off: "mic.slash.fill", help: "Microphone", isOn: $model.micEnabled,
                          permission: model.micPermission, request: { await model.requestMicrophone() }) {
                    VStack(spacing: 5) {
                        Picker("", selection: Binding(get: { model.resolvedMicID }, set: { model.micID = $0 })) {
                            ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        LevelMeter(level: model.micEnabled ? model.micLevel : 0)
                            .padding(.horizontal, 4)
                    }
                }
                HStack(spacing: 10) {
                    IconToggle(on: "speaker.wave.2.fill", off: "speaker.slash.fill", isOn: $model.systemAudioEnabled, help: "System audio")
                    Text("System audio")
                        .font(Theme.rounded(12))
                        .foregroundStyle(model.systemAudioEnabled ? .white.opacity(0.85) : Theme.dim)
                    Spacer()
                }
            }
        }
    }
}

struct DeviceRow<Content: View>: View {
    let on: String
    let off: String
    let help: String
    @Binding var isOn: Bool
    let permission: AVAuthorizationStatus
    let request: () async -> Void
    @ViewBuilder var content: Content

    init(on: String, off: String, help: String, isOn: Binding<Bool>, permission: AVAuthorizationStatus,
         request: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self.on = on
        self.off = off
        self.help = help
        self._isOn = isOn
        self.permission = permission
        self.request = request
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            IconToggle(on: on, off: off, isOn: $isOn, help: help)
            if permission == .authorized {
                content
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.45)
            } else {
                Button { Task { await request() } } label: {
                    Text(permission == .notDetermined ? "Allow \(help)" : "Open Settings")
                        .font(Theme.rounded(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}

struct RecordBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            IconToggle(on: "eye.fill", off: "eye.slash.fill", isOn: $model.previewVisible, help: "Preview   ⌃⌥V", size: 40)
            RecordButton(model: model)
            if model.isRecording {
                IconButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: "Pause   ⌃⌥P", size: 40) { model.togglePause() }
                    .transition(.scale.combined(with: .opacity))
            }
            IconButton(symbol: "folder.fill", help: "Recordings", size: 40) { model.openFolder() }
        }
        .padding(.top, 2)
        .animation(.snappy(duration: 0.25), value: model.isRecording)
    }
}

struct RecordButton: View {
    @Bindable var model: AppModel
    @State private var pulse = false

    var body: some View {
        Button { model.toggleRecording() } label: {
            HStack(spacing: 9) {
                if model.isStarting || model.isFinishing {
                    ProgressView().controlSize(.small).tint(.white)
                } else if model.isRecording {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white).frame(width: 12, height: 12)
                    Text(Self.format(model.elapsed))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                } else {
                    Circle().fill(.white).frame(width: 12, height: 12)
                    Text("Record").font(Theme.rounded(14, .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(Theme.recordGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .shadow(color: Theme.record.opacity(model.isRecording && !model.isPaused ? (pulse ? 0.7 : 0.2) : 0.25),
                    radius: model.isRecording ? 14 : 6)
            .opacity(model.isPaused ? 0.65 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isStarting || model.isFinishing)
        .help("Record   ⌃⌥R")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct OutputSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            row("Size") { TextSegments(items: ResolutionPreset.allCases.map { ($0, $0.label) }, selection: $model.resolution) }
            row("Frame") { TextSegments(items: AspectPreset.allCases.map { ($0, $0.label) }, selection: $model.aspect) }
            row("FPS") { TextSegments(items: [(30, "30"), (60, "60")], selection: $model.fps) }
            row("Codec") { TextSegments(items: VideoCodec.allCases.map { ($0, $0.label) }, selection: $model.codec) }
            row("Quality") { TextSegments(items: Quality.allCases.map { ($0, $0.label) }, selection: $model.quality) }
            row("Screen") { TextSegments(items: [(ScreenFit.fit, "Fit"), (ScreenFit.fill, "Fill")], selection: $model.screenFit) }
            Divider().gridCellColumns(2)
            row("Cursor") { toggle($model.showsCursor) }
            row("Preview on top") { toggle($model.previewOnTop) }
            row("Export after") { toggle($model.openExportAfterRecording) }
            row("Folder") {
                Button { model.chooseFolder() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                        Text(model.saveFolder.lastPathComponent).lineLimit(1)
                    }
                    .font(Theme.rounded(11, .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .disabled(model.isRecording || model.isStarting)
        .preferredColorScheme(.dark)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(title).font(Theme.rounded(11, .medium)).foregroundStyle(Theme.dim).gridColumnAlignment(.trailing)
            content()
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View {
        Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.violet)
    }
}
