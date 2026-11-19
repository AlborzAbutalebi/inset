import AppKit
import CoreMedia
import ScreenCaptureKit

/// What the capture pipeline should be doing right now.
struct PipelineConfig: Equatable {
    var active = false
    var screen: ScreenTarget?
    var cameraID: String?
    var micID: String?
    var systemAudio = false
    var fps = 30
    var canvas = CGSize(width: 1920, height: 1080)
    var screenFit: ScreenFit = .fit
    var showsCursor = true
}

/// Owns the sources, compositor and recorder, and keeps them in sync with a `PipelineConfig`.
/// Nothing runs (zero CPU/GPU) unless the preview is open or a recording is in progress.
@MainActor
final class Studio {
    let renderLoop: RenderLoop
    private let screen = ScreenSource()
    private let camera = CameraSource()
    private let mic = MicSource()
    private(set) var recorder: Recorder?

    private var desired = PipelineConfig()
    private var applied = PipelineConfig()
    private var chain: Task<Void, Never>?
    private var cameraRunning: String?
    private var micRunning: String?
    private var screenPixelScale: CGFloat = 2
    private var windowWatch: Timer?
    private var watchedWindowSize: CGSize = .zero

    var onError: ((String) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var onScreenAspect: ((CGFloat) -> Void)?
    var onCameraAspect: ((CGFloat) -> Void)?

    private let aspectLock = UnfairLock()
    nonisolated(unsafe) private var lastScreenAspect: CGFloat = 0
    nonisolated(unsafe) private var lastCameraAspect: CGFloat = 0

    init() throws {
        renderLoop = RenderLoop(compositor: try Compositor())
        let frames = renderLoop.frames
        let loop = renderLoop

        screen.onVideo = { [weak self] frame in
            frames.setScreen(frame)
            self?.reportAspect(frame.aspect, camera: false)
        }
        screen.onAudio = { sb in loop.recorder?.appendAudio(sb, track: .system) }
        screen.onStop = { [weak self] error in
            Task { @MainActor in self?.screenStopped(error) }
        }
        camera.onFrame = { [weak self] frame in
            frames.setCamera(frame)
            self?.reportAspect(frame.aspect, camera: true)
        }
        mic.onSample = { sb in loop.recorder?.appendAudio(sb, track: .microphone) }
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.onMicLevel?(level) }
        }
    }

    nonisolated private func reportAspect(_ aspect: CGFloat, camera: Bool) {
        let changed: Bool = aspectLock.withLock {
            let last = camera ? lastCameraAspect : lastScreenAspect
            guard abs(last - aspect) > 0.005 else { return false }
            if camera { lastCameraAspect = aspect } else { lastScreenAspect = aspect }
            return true
        }
        guard changed else { return }
        Task { @MainActor [weak self] in
            if camera { self?.onCameraAspect?(aspect) } else { self?.onScreenAspect?(aspect) }
        }
    }

    // MARK: Reconciliation

    /// Applies `config`. Calls are serialised and coalesced; await the task to know it's live.
    @discardableResult
    func apply(_ config: PipelineConfig) -> Task<Void, Never> {
        desired = config
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            guard self.desired != self.applied else { return }
            await self.step(self.desired)
        }
        chain = task
        return task
    }

    /// Forget what's live so the next `apply` restarts everything (e.g. after a permission grant).
    func invalidate() { applied = PipelineConfig() }

    /// Rebuilds the display filter so newly shown Inset windows (e.g. the preview) stay excluded.
    func refreshScreenFilter() {
        guard applied.active, case .display = applied.screen else { return }
        applied.screen = nil
        apply(desired)
    }

    private func step(_ target: PipelineConfig) async {
        defer { applied = target }
        guard target.active else {
            renderLoop.stop()
            stopWindowWatch()
            await screen.stop()
            renderLoop.frames.setScreen(nil)
            if cameraRunning != nil { await camera.stop(); cameraRunning = nil }
            renderLoop.frames.setCamera(nil)
            if micRunning != nil { await mic.stop(); micRunning = nil }
            return
        }
        renderLoop.canvas = target.canvas
        renderLoop.start(fps: target.fps)

        await applyScreen(target)
        await applyCamera(target)
        await applyMic(target)
    }

    private func applyScreen(_ target: PipelineConfig) async {
        let screenChanged = target.screen != applied.screen || !screen.isRunning
        let configChanged = target.fps != applied.fps || target.canvas != applied.canvas
            || target.screenFit != applied.screenFit || target.showsCursor != applied.showsCursor
            || target.systemAudio != applied.systemAudio
        guard screenChanged || configChanged else { return }

        guard let source = target.screen, Permissions.screen else {
            stopWindowWatch()
            await screen.stop()
            renderLoop.frames.setScreen(nil)
            return
        }
        do {
            // Include off-screen windows so Inset's hidden windows are known and can be excluded.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let (filter, isWindow) = makeFilter(source, content) else {
                await screen.stop()
                renderLoop.frames.setScreen(nil)
                onError?(isWindowTarget(source) ? "That window is gone." : "That display is gone.")
                return
            }
            screenPixelScale = CGFloat(filter.pointPixelScale)
            let points = filter.contentRect.size
            renderLoop.screenAspectHint = points.width / max(points.height, 1)
            let config = makeConfiguration(points: points, target: target)

            if screen.isRunning && !screenChanged {
                try await screen.update(configuration: config)
            } else if screen.isRunning {
                try await screen.update(filter: filter, isWindow: isWindow)
                try await screen.update(configuration: config)
            } else {
                try await screen.start(filter: filter, configuration: config, isWindow: isWindow)
            }
            if case .window(let id) = source { startWindowWatch(id, size: points) } else { stopWindowWatch() }
        } catch {
            onError?("Screen capture failed: \(error.localizedDescription)")
        }
    }

    private func isWindowTarget(_ t: ScreenTarget) -> Bool {
        if case .window = t { return true }
        return false
    }

    private func makeFilter(_ target: ScreenTarget, _ content: SCShareableContent) -> (SCContentFilter, Bool)? {
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // Exclude Inset's own windows (panel + preview) so they never appear in the recording.
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), false)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            return (SCContentFilter(desktopIndependentWindow: window), true)
        }
    }

    /// Capture no more pixels than the canvas can show — the GPU scaler does the rest for free.
    private func makeConfiguration(points: CGSize, target: PipelineConfig) -> SCStreamConfiguration {
        let native = CGSize(width: points.width * screenPixelScale, height: points.height * screenPixelScale)
        let aspect = native.width / max(native.height, 1)
        let full = CGRect(origin: .zero, size: target.canvas)
        let needed: CGSize
        if target.screenFit == .fit {
            needed = Geometry.fit(aspect: aspect, in: full).size
        } else {
            let s = max(target.canvas.width / native.width, target.canvas.height / native.height)
            needed = CGSize(width: native.width * s, height: native.height * s)
        }
        let scale = min(1, needed.width / max(native.width, 1))
        let size = CGSize(width: max(64, native.width * scale), height: max(64, native.height * scale))
        return ScreenSource.configuration(pixelSize: size, fps: target.fps, showsCursor: target.showsCursor,
                                          captureAudio: target.systemAudio)
    }

    private func applyCamera(_ target: PipelineConfig) async {
        let wantID = Permissions.camera == .authorized ? target.cameraID : nil
        let needsRestart = wantID != cameraRunning || target.fps != applied.fps
            || (target.canvas.height <= 720) != (applied.canvas.height <= 720)
        guard needsRestart else { return }
        if let id = wantID {
            do {
                let height = min(target.canvas.width, target.canvas.height) <= 720 ? 720 : 1080
                try await camera.start(deviceID: id, targetHeight: height, fps: target.fps)
                cameraRunning = id
            } catch {
                cameraRunning = nil
                onError?("Camera: \(error.localizedDescription)")
            }
        } else if cameraRunning != nil {
            await camera.stop()
            cameraRunning = nil
            renderLoop.frames.setCamera(nil)
        }
    }

    private func applyMic(_ target: PipelineConfig) async {
        let wantID = Permissions.microphone == .authorized ? target.micID : nil
        guard wantID != micRunning else { return }
        if let id = wantID {
            do {
                try await mic.start(deviceID: id)
                micRunning = id
            } catch {
                micRunning = nil
                onError?("Microphone: \(error.localizedDescription)")
            }
        } else {
            await mic.stop()
            micRunning = nil
        }
    }

    private func screenStopped(_ error: Error) {
        renderLoop.frames.setScreen(nil)
        stopWindowWatch()
        applied.screen = nil
        let code = (error as NSError).code
        // -3817 = user stopped sharing; -3815/-3821 = window/display went away.
        if code != -3817 { onError?("Screen capture stopped.") }
        apply(desired)
    }

    // MARK: Window resize tracking

    private func startWindowWatch(_ id: CGWindowID, size: CGSize) {
        stopWindowWatch()
        watchedWindowSize = size
        windowWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWindow(id) }
        }
    }

    private func stopWindowWatch() {
        windowWatch?.invalidate()
        windowWatch = nil
    }

    private func checkWindow(_ id: CGWindowID) {
        guard let bounds = SourceCatalog.windowBounds(id) else { return }
        let size = bounds.size
        guard abs(size.width - watchedWindowSize.width) > 1 || abs(size.height - watchedWindowSize.height) > 1 else { return }
        watchedWindowSize = size
        renderLoop.screenAspectHint = size.width / max(size.height, 1)
        let config = makeConfiguration(points: size, target: applied)
        Task { try? await screen.update(configuration: config) }
    }

    // MARK: Recording

    func startRecording(_ settings: RecordingSettings) async throws {
        // Give freshly started sources a moment to deliver their first frames.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let screenReady = desired.screen == nil || !Permissions.screen || renderLoop.frames.hasScreen
            let cameraReady = cameraRunning == nil || renderLoop.frames.hasCamera
            if screenReady && cameraReady { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let rec = try Recorder(settings: settings)
        if cameraRunning != nil {
            let delay = min(max(renderLoop.cameraLatency, 0), 0.2)
            rec.audioDelay = CMTime(seconds: delay, preferredTimescale: 48_000)
        }
        recorder = rec
        renderLoop.canvas = settings.canvas
        renderLoop.recorder = rec
    }

    func pause() { recorder?.pause() }
    func resume() { recorder?.resume() }

    func stopRecording() async throws -> URL {
        guard let rec = recorder else { throw InsetError.message("Not recording.") }
        recorder = nil
        renderLoop.recorder = nil
        let url = try await rec.finish()
        if rec.hasAudioTracks > 1 {
            do { try await AudioMixdown.mixIfNeeded(url) } catch { onError?("Audio mix failed; tracks kept separate.") }
        }
        return url
    }
}
