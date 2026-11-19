import AppKit
import AVKit
import Photos
import SwiftUI

/// Where a finished recording can go.
enum ExportService {
    /// AirDrop to a nearby iPhone — videos received by AirDrop land straight in its Photos app.
    @MainActor
    static func sendToIPhone(_ url: URL) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else { return false }
        service.perform(withItems: [url])
        return true
    }

    /// Adds the video to the Mac's Photos library; with iCloud Photos on it appears on the iPhone too.
    static func addToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw InsetError.message("Photos access is off")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }

    @MainActor
    static func saveCopy(_ url: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let dest = panel.url else { return nil }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

struct ExportView: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var info = ""
    @State private var status: String?
    @State private var working = false
    @State private var trashed = false

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 14) {
            PlayerView(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                .padding(.top, 22)

            HStack {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Theme.rounded(13, .semibold))
                    .lineLimit(1)
                Spacer()
                Text(info).font(Theme.rounded(11)).foregroundStyle(Theme.dim)
            }

            HStack(spacing: 10) {
                ExportButton(symbol: "iphone.and.arrow.forward", title: "iPhone", primary: true) {
                    if ExportService.sendToIPhone(url) {
                        flash("Choose your iPhone")
                    } else {
                        flash("AirDrop unavailable")
                    }
                }
                .help("AirDrop to iPhone — lands in Photos")
                ExportButton(symbol: "photo.on.rectangle.angled", title: "Photos") {
                    working = true
                    Task {
                        do {
                            try await ExportService.addToPhotos(url)
                            flash("Added to Photos")
                        } catch {
                            flash(error.localizedDescription)
                        }
                        working = false
                    }
                }
                .help("Add to Photos — syncs to iPhone via iCloud")
                ExportButton(symbol: "square.and.arrow.down", title: "Save") {
                    if ExportService.saveCopy(url) != nil { flash("Saved") }
                }
                .help("Save a copy")
                ShareLink(item: url) {
                    ExportButtonLabel(symbol: "square.and.arrow.up", title: "Share", primary: false)
                }
                .buttonStyle(.plain)
                .help("Share")
                ExportButton(symbol: "folder", title: "Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .help("Show in Finder")
                ExportButton(symbol: "trash", title: "Delete") {
                    player.pause()
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        trashed = true
                        NSApp.keyWindow?.close()
                    }
                }
                .help("Move to Trash")
            }
            .disabled(working || trashed)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(minWidth: 460, minHeight: 380)
        .background(VisualEffect(material: .hudWindow).ignoresSafeArea())
        .overlay(alignment: .top) {
            if let status {
                Text(status)
                    .font(Theme.rounded(12, .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .padding(.top, 34)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: status)
        .preferredColorScheme(.dark)
        .task { await loadInfo() }
        .onDisappear { player.pause() }
    }

    private func flash(_ text: String) {
        status = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if status == text { status = nil }
        }
    }

    private func loadInfo() async {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        if let d = try? await asset.load(.duration) { parts.append(RecordButton.format(d.seconds)) }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        info = parts.joined(separator: "  ·  ")
    }
}

struct ExportButtonLabel: View {
    let symbol: String
    let title: String
    let primary: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            Text(title).font(Theme.rounded(10.5, .semibold))
        }
        .foregroundStyle(.white.opacity(primary || hover ? 1 : 0.8))
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(hover ? 0.12 : 0.06)))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hover = $0 }
    }
}

struct ExportButton: View {
    let symbol: String
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { ExportButtonLabel(symbol: symbol, title: title, primary: primary) }
            .buttonStyle(.plain)
    }
}
