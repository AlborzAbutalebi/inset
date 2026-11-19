import CoreMedia
import Metal
import QuartzCore

final class UnfairLock: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    deinit { ptr.deinitialize(count: 1); ptr.deallocate() }
    @inline(__always) func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(ptr)
        defer { os_unfair_lock_unlock(ptr) }
        return try body()
    }
}

/// Latest frame from each source. Written by capture queues, read by the render loop.
final class FrameStore: @unchecked Sendable {
    private let lock = UnfairLock()
    private var screen: SourceFrame?
    private var camera: SourceFrame?
    private var version = 0

    func setScreen(_ f: SourceFrame?) { lock.withLock { screen = f; version &+= 1 } }
    func setCamera(_ f: SourceFrame?) { lock.withLock { camera = f; version &+= 1 } }
    func snapshot() -> (screen: SourceFrame?, camera: SourceFrame?, version: Int) {
        lock.withLock { (screen, camera, version) }
    }
    var hasScreen: Bool { lock.withLock { screen != nil } }
    var hasCamera: Bool { lock.withLock { camera != nil } }
}

/// Drives composition at the output frame rate. Recording and preview are decoupled so a
/// hidden or slow preview can never stall the recording.
final class RenderLoop: @unchecked Sendable {
    let compositor: Compositor
    let frames = FrameStore()

    private let queue = DispatchQueue(label: "app.inset.render", qos: .userInteractive)
    private let previewQueue = DispatchQueue(label: "app.inset.preview", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var timerFPS = 0

    private let lock = UnfairLock()
    private var _layout = LayoutSnapshot()
    private var _canvas = CGSize(width: 1920, height: 1080)
    private weak var _preview: CAMetalLayer?
    private var _recorder: Recorder?
    private var _screenAspectHint: CGFloat = 16 / 9
    private var _cameraLatency: Double = 0.06
    private var _previewBusy = false

    // render-queue only
    private let animator = SceneAnimator()
    private let inflight = DispatchSemaphore(value: 3)
    private var lastPreviewKey: PreviewKey?

    private struct PreviewKey: Equatable {
        var version: Int
        var scene: SceneState
        var layout: LayoutSnapshot
        var canvas: CGSize
        var drawable: CGSize
    }

    init(compositor: Compositor) { self.compositor = compositor }

    var layout: LayoutSnapshot {
        get { lock.withLock { _layout } }
        set { lock.withLock { _layout = newValue } }
    }
    var canvas: CGSize {
        get { lock.withLock { _canvas } }
        set { lock.withLock { _canvas = newValue } }
    }
    var preview: CAMetalLayer? {
        get { lock.withLock { _preview } }
        set { lock.withLock { _preview = newValue } }
    }
    var recorder: Recorder? {
        get { lock.withLock { _recorder } }
        set { lock.withLock { _recorder = newValue } }
    }
    var screenAspectHint: CGFloat {
        get { lock.withLock { _screenAspectHint } }
        set { lock.withLock { _screenAspectHint = newValue } }
    }
    /// Smoothed camera pipeline latency, used to keep lips in sync with audio.
    var cameraLatency: Double { lock.withLock { _cameraLatency } }

    var isRunning: Bool { queue.sync { timer != nil } }

    func start(fps: Int) {
        queue.async { [self] in
            guard timer == nil || timerFPS != fps else { return }
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = 1.0 / Double(fps)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            timerFPS = fps
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            timerFPS = 0
            lastPreviewKey = nil
        }
    }

    /// Forces the preview to redraw on the next tick (e.g. after a resize).
    func invalidatePreview() { queue.async { [self] in lastPreviewKey = nil } }

    private func tick() {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let now = hostNow.seconds
        let (layout, canvas, preview, recorder, hint) = lock.withLock {
            (_layout, _canvas, _preview, _recorder, _screenAspectHint)
        }
        let snap = frames.snapshot()
        let screenAspect = snap.screen?.aspect ?? hint
        let cameraAspect = snap.camera?.aspect ?? 16 / 9
        let target = Geometry.target(layout, canvas: canvas, screenAspect: screenAspect, cameraAspect: cameraAspect)
        let scene = animator.state(target: target, layout: layout, now: now)

        if let cam = snap.camera {
            let lat = now - cam.hostTime.seconds
            if lat > 0, lat < 0.5 { lock.withLock { _cameraLatency = _cameraLatency * 0.96 + lat * 0.04 } }
        }

        let recording = recorder?.acceptsVideo == true
        let wantsPreview = preview != nil && (preview?.drawableSize.width ?? 0) > 0
        guard recording || wantsPreview else { return }

        var inputs = Compositor.Inputs(screen: snap.screen, camera: snap.camera)
        var retained: [AnyObject] = []
        if let s = snap.screen, let (tex, cv) = compositor.texture(for: s.buffer) {
            inputs.screenTexture = tex
            retained.append(cv)
            retained.append(s.buffer)
        }
        if let c = snap.camera, let (tex, cv) = compositor.texture(for: c.buffer) {
            inputs.cameraTexture = tex
            retained.append(cv)
            retained.append(c.buffer)
        }
        let bg = layout.background
        let canvasClear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)

        if recording, let recorder, inflight.wait(timeout: .now()) == .success {
            if let pb = compositor.makeOutputBuffer(size: canvas),
               let (tex, cv) = compositor.texture(for: pb),
               let cb = compositor.commandQueue.makeCommandBuffer() {
                compositor.encode(scene: scene, layout: layout, canvas: canvas, inputs: inputs, into: tex,
                                  commandBuffer: cb, scale: 1, offset: .zero, clear: canvasClear)
                let keep = retained + [cv]
                cb.addCompletedHandler { [inflight] _ in
                    recorder.appendVideo(pb, hostTime: hostNow)
                    _ = keep
                    inflight.signal()
                }
                cb.commit()
            } else {
                inflight.signal()
            }
        }

        if wantsPreview, let preview {
            let key = PreviewKey(version: snap.version, scene: scene, layout: layout, canvas: canvas, drawable: preview.drawableSize)
            let busy = lock.withLock { () -> Bool in
                if _previewBusy { return true }
                _previewBusy = true
                return false
            }
            if !busy {
                if key == lastPreviewKey {
                    lock.withLock { _previewBusy = false }
                } else {
                    lastPreviewKey = key
                    let keep = retained
                    previewQueue.async { [weak self] in
                        guard let self else { return }
                        defer { self.lock.withLock { self._previewBusy = false } }
                        guard let drawable = preview.nextDrawable(),
                              let cb = self.compositor.commandQueue.makeCommandBuffer() else { return }
                        let ds = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                        let s = min(ds.width / canvas.width, ds.height / canvas.height)
                        let off = CGPoint(x: (ds.width - canvas.width * s) / 2, y: (ds.height - canvas.height * s) / 2)
                        self.compositor.encode(scene: scene, layout: layout, canvas: canvas, inputs: inputs,
                                               into: drawable.texture, commandBuffer: cb, scale: s, offset: off,
                                               clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
                        cb.present(drawable)
                        cb.addCompletedHandler { _ in _ = keep }
                        cb.commit()
                    }
                }
            }
        }
        compositor.flushCache()
    }
}
