import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

enum ResolutionPreset: Int, CaseIterable, Codable {
    case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
    var label: String { self == .p2160 ? "4K" : "\(rawValue)p" }
}

enum AspectPreset: String, CaseIterable, Codable {
    case source, wide, wide1610, vertical, square, classic
    var label: String {
        switch self {
        case .source: "Auto"
        case .wide: "16:9"
        case .wide1610: "16:10"
        case .vertical: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .source: nil
        case .wide: 16 / 9
        case .wide1610: 16 / 10
        case .vertical: 9 / 16
        case .square: 1
        case .classic: 4 / 3
        }
    }
}

/// Settings that survive relaunches.
private struct StoredSettings: Codable {
    var mode: LayoutMode = .screenWithCamera
    var screenKind: ScreenKind = .display
    var displayID: UInt32?
    var cameraEnabled = true
    var cameraID: String?
    var micEnabled = true
    var micID: String?
    var systemAudio = true
    var cameraShape: CameraShape = .circle
    var roundness = 0.22
    var mirror = true
    var border = false
    var shadow = true
    var smooth = true
    var screenFit: ScreenFit = .fit
    var cameraPlacement = LayoutSnapshot().cameraPlacement
    var screenPlacement = LayoutSnapshot().screenPlacement
    var resolution: ResolutionPreset = .p1080
    var aspect: AspectPreset = .source
    var fps = 30
    var codec: VideoCodec = .hevc
    var quality: Quality = .high
    var cursor = true
    var folder: String?
    var exportAfter = true
    var preview = false
    var previewOnTop = true
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Settings
    var mode: LayoutMode = .screenWithCamera { didSet { settingsChanged() } }
    var screenKind: ScreenKind = .display { didSet { settingsChanged(pipeline: true) } }
    var selectedDisplayID: CGDirectDisplayID? { didSet { settingsChanged(pipeline: true) } }
    var selectedWindowID: CGWindowID? { didSet { settingsChanged(pipeline: true) } }
    var cameraEnabled = true { didSet { settingsChanged(pipeline: true) } }
    var cameraID: String? { didSet { settingsChanged(pipeline: true) } }
    var micEnabled = true { didSet { settingsChanged(pipeline: true) } }
    var micID: String? { didSet { settingsChanged(pipeline: true) } }
    var systemAudioEnabled = true { didSet { settingsChanged() } }
    var cameraShape: CameraShape = .circle { didSet { settingsChanged() } }
    var roundness = 0.22 { didSet { settingsChanged() } }
    var mirrorCamera = true { didSet { settingsChanged() } }
    var border = false { didSet { settingsChanged() } }
    var shadow = true { didSet { settingsChanged() } }
    var smoothTransitions = true { didSet { settingsChanged() } }
    var screenFit: ScreenFit = .fit { didSet { settingsChanged(pipeline: true) } }
    var cameraPlacement = LayoutSnapshot().cameraPlacement { didSet { settingsChanged() } }
    var screenPlacement = LayoutSnapshot().screenPlacement { didSet { settingsChanged() } }
    var resolution: ResolutionPreset = .p1080 { didSet { settingsChanged(pipeline: true) } }
    var aspect: AspectPreset = .source { didSet { settingsChanged(pipeline: true) } }
    var fps = 30 { didSet { settingsChanged(pipeline: true) } }
    var codec: VideoCodec = .hevc { didSet { settingsChanged() } }
    var quality: Quality = .high { didSet { settingsChanged() } }
    var showsCursor = true { didSet { settingsChanged(pipeline: true) } }
    var saveFolder: URL = AppModel.defaultFolder { didSet { settingsChanged() } }
    var openExportAfterRecording = true { didSet { settingsChanged() } }
    var previewVisible = false {
        didSet {
            guard !loading, oldValue != previewVisible else { return }
            settingsChanged(pipeline: true)
            if previewVisible {
                WindowManager.shared.showPreview()
                Task { await requestDevicePermissionsIfNeeded() }
            } else {
                WindowManager.shared.hidePreview()
            }
        }
    }
    var previewOnTop = true {
        didSet {
            guard !loading else { return }
            settingsChanged()
            WindowManager.shared.updatePreviewLevel()
        }
    }

    // MARK: Runtime state
    var displays: [DisplayItem] = []
    var windows: [WindowItem] = []
    var thumbnails: [ScreenTarget: NSImage] = [:]
    var cameras: [DeviceItem] = []
    var microphones: [DeviceItem] = []
    var screenPermission = false
    var screenPermissionRequested = false
    var cameraPermission: AVAuthorizationStatus = .notDetermined
    var micPermission: AVAuthorizationStatus = .notDetermined
    var isRecording = false
    var isPaused = false
    var isStarting = false
    var isFinishing = false
    var elapsed: TimeInterval = 0
    var micLevel: Float = 0
    var toast: String?
    var liveScreenAspect: CGFloat?
    var cameraAspect: CGFloat = 16 / 9
    private(set) var recordingCanvas: CGSize?

    @ObservationIgnored private(set) var studio: Studio?
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var pipelineScheduled = false
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var permissionPoll: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastScreenRefresh = Date.distantPast

    static let defaultFolder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Inset", isDirectory: true)

    private init() {
        load()
        loading = false
    }

    // MARK: Lifecycle

    func bootstrap() {
        do {
            let studio = try Studio()
            studio.onError = { [weak self] in self?.show($0) }
            studio.onMicLevel = { [weak self] in self?.micLevel = $0 }
            studio.onScreenAspect = { [weak self] in self?.liveScreenAspect = $0; self?.schedulePipeline() }
            studio.onCameraAspect = { [weak self] in self?.cameraAspect = $0 }
            self.studio = studio
        } catch {
            show(error.localizedDescription)
        }
        refreshPermissions()
        refreshDevices()
        Task { await refreshScreens() }
        pushLayout()
        schedulePipeline()
        if previewVisible { WindowManager.shared.showPreview() }

        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refreshScreens() } }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = (self.screenPermission, self.cameraPermission, self.micPermission)
                self.refreshPermissions()
                if before != (self.screenPermission, self.cameraPermission, self.micPermission) {
                    self.studio?.invalidate()
                    self.schedulePipeline()
                    Task { await self.refreshScreens() }
                } else if Date().timeIntervalSince(self.lastScreenRefresh) > 5 {
                    Task { await self.refreshScreens() }
                }
            }
        })
    }

    // MARK: Derived

    var screenTarget: ScreenTarget? {
        switch screenKind {
        case .display:
            let id = selectedDisplayID.flatMap { id in displays.contains { $0.id == id } ? id : nil }
                ?? displays.first(where: { $0.id == CGMainDisplayID() })?.id ?? displays.first?.id
            return id.map { .display($0) }
        case .window:
            return selectedWindowID.map { .window($0) }
        }
    }

    var screenAspect: CGFloat {
        // Windows can be resized live; displays have a fixed, known shape.
        if screenKind == .window, let live = liveScreenAspect, studio?.renderLoop.frames.hasScreen == true { return live }
        switch screenTarget {
        case .display(let id): if let d = displays.first(where: { $0.id == id }) { return d.size.width / max(d.size.height, 1) }
        case .window(let id): if let w = windows.first(where: { $0.id == id }) { return w.frame.width / max(w.frame.height, 1) }
        case nil: break
        }
        return 16 / 9
    }

    var canvasSize: CGSize {
        if let recordingCanvas { return recordingCanvas }
        let a = min(max(aspect.ratio ?? screenAspect, 0.5), 2.4)
        let short = CGFloat(resolution.rawValue)
        let size = a >= 1 ? CGSize(width: short * a, height: short) : CGSize(width: short, height: short / a)
        return Geometry.evenSize(size)
    }

    var resolvedCameraID: String? {
        if let cameraID, cameras.contains(where: { $0.id == cameraID }) { return cameraID }
        return SourceCatalog.defaultCameraID() ?? cameras.first?.id
    }

    var resolvedMicID: String? {
        if let micID, microphones.contains(where: { $0.id == micID }) { return micID }
        return SourceCatalog.defaultMicrophoneID() ?? microphones.first?.id
    }

    var layoutSnapshot: LayoutSnapshot {
        var s = LayoutSnapshot()
        s.mode = mode
        s.cameraPlacement = cameraPlacement
        s.screenPlacement = screenPlacement
        s.cameraShape = cameraShape
        s.roundness = roundness
        s.mirrorCamera = mirrorCamera
        s.screenFit = screenFit
        s.border = border
        s.shadow = shadow
        s.transitionDuration = smoothTransitions ? 0.42 : 0
        return s
    }

    private var pipelineConfig: PipelineConfig {
        let busy = isRecording || isStarting || isFinishing
        return PipelineConfig(
            active: previewVisible || busy,
            screen: screenPermission ? screenTarget : nil,
            cameraID: cameraEnabled && cameraPermission == .authorized ? resolvedCameraID : nil,
            micID: micEnabled && micPermission == .authorized ? resolvedMicID : nil,
            systemAudio: systemAudioEnabled && (isRecording || isStarting),
            fps: fps,
            canvas: canvasSize,
            screenFit: screenFit,
            showsCursor: showsCursor)
    }

    // MARK: Actions

    func setMode(_ m: LayoutMode) { mode = m }
    func swapMode() { mode = mode.swapped }

    func setPlacement(_ layer: SceneLayer, _ p: Placement) {
        if layer == .camera { cameraPlacement = p } else { screenPlacement = p }
    }

    func placement(_ layer: SceneLayer) -> Placement { layer == .camera ? cameraPlacement : screenPlacement }

    func toggleRecording() {
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    func togglePause() {
        guard isRecording, let studio else { return }
        isPaused.toggle()
        isPaused ? studio.pause() : studio.resume()
    }

    func startRecording() async {
        guard !isRecording, !isStarting, !isFinishing, let studio else { return }
        await requestDevicePermissionsIfNeeded()
        guard screenPermission || (cameraEnabled && cameraPermission == .authorized) else {
            show("Allow Screen Recording first")
            return
        }
        isStarting = true
        recordingCanvas = canvasSize
        await studio.apply(pipelineConfig).value

        let config = pipelineConfig
        let settings = RecordingSettings(
            url: nextRecordingURL(), canvas: recordingCanvas!, fps: fps, codec: codec, quality: quality,
            microphone: config.micID != nil, systemAudio: config.systemAudio && config.screen != nil)
        do {
            try await studio.startRecording(settings)
            isRecording = true
            isPaused = false
            elapsed = 0
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let rec = self.studio?.recorder else { return }
                    self.elapsed = rec.duration
                }
            }
        } catch {
            recordingCanvas = nil
            show(error.localizedDescription)
        }
        isStarting = false
        schedulePipeline()
    }

    func stopRecording() async {
        guard isRecording, let studio else { return }
        isFinishing = true
        isRecording = false
        isPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        do {
            let url = try await studio.stopRecording()
            if openExportAfterRecording { WindowManager.shared.showExport(url) } else { show("Saved") }
        } catch {
            show(error.localizedDescription)
        }
        isFinishing = false
        recordingCanvas = nil
        schedulePipeline()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }

    private func nextRecordingURL() -> URL {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return saveFolder.appendingPathComponent("Inset \(f.string(from: Date())).mp4")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        screenPermission = Permissions.screen
        cameraPermission = Permissions.camera
        micPermission = Permissions.microphone
    }

    func requestScreen() {
        screenPermissionRequested = true
        if !Permissions.requestScreen() {
            Permissions.openPrivacySettings("Privacy_ScreenCapture")
        }
        permissionPoll?.invalidate()
        var ticks = 0
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                ticks += 1
                guard let self else { t.invalidate(); return }
                if Permissions.screen {
                    t.invalidate()
                    self.screenPermission = true
                    self.studio?.invalidate()
                    self.schedulePipeline()
                    Task { await self.refreshScreens() }
                } else if ticks > 120 {
                    t.invalidate()
                }
            }
        }
    }

    func requestDevicePermissionsIfNeeded() async {
        if cameraEnabled && cameraPermission == .notDetermined { await requestCamera() }
        if micEnabled && micPermission == .notDetermined { await requestMicrophone() }
    }

    func requestCamera() async {
        if Permissions.camera == .denied { Permissions.openPrivacySettings("Privacy_Camera"); return }
        _ = await Permissions.request(.video)
        cameraPermission = Permissions.camera
        refreshDevices()
        schedulePipeline()
    }

    func requestMicrophone() async {
        if Permissions.microphone == .denied { Permissions.openPrivacySettings("Privacy_Microphone"); return }
        _ = await Permissions.request(.audio)
        micPermission = Permissions.microphone
        refreshDevices()
        schedulePipeline()
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Sources

    func refreshDevices() {
        cameras = SourceCatalog.cameras()
        microphones = SourceCatalog.microphones()
        schedulePipeline()
    }

    func refreshScreens() async {
        lastScreenRefresh = Date()
        screenPermission = Permissions.screen
        guard screenPermission else { return }
        guard let content = try? await SourceCatalog.shareable() else { return }
        displays = SourceCatalog.displays(content)
        let newWindows = SourceCatalog.windows(content)
        windows = newWindows
        if case .window = screenKind, let id = selectedWindowID, !newWindows.contains(where: { $0.id == id }), !isRecording {
            selectedWindowID = nil
        }
        schedulePipeline()
        await loadThumbnails(content)
    }

    private func loadThumbnails(_ content: SCShareableContent) async {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        for d in content.displays {
            let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            if let img = await SourceCatalog.thumbnail(filter: filter, maxWidth: 200) { thumbnails[.display(d.displayID)] = img }
        }
        let ids = Set(windows.map(\.id))
        for w in content.windows where ids.contains(w.windowID) {
            let filter = SCContentFilter(desktopIndependentWindow: w)
            if let img = await SourceCatalog.thumbnail(filter: filter, maxWidth: 160) { thumbnails[.window(w.windowID)] = img }
        }
    }

    // MARK: Plumbing

    private func settingsChanged(pipeline: Bool = false) {
        guard !loading else { return }
        save()
        pushLayout()
        if pipeline { schedulePipeline() }
    }

    private func pushLayout() {
        studio?.renderLoop.layout = layoutSnapshot
        WindowManager.shared.layoutDidChange()
    }

    func schedulePipeline() {
        guard !pipelineScheduled else { return }
        pipelineScheduled = true
        DispatchQueue.main.async { [self] in
            pipelineScheduled = false
            guard let studio else { return }
            let config = pipelineConfig
            studio.renderLoop.canvas = config.canvas
            studio.apply(config)
            WindowManager.shared.canvasDidChange(config.canvas)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(StoredSettings.self, from: data) else { return }
        mode = s.mode
        screenKind = s.screenKind
        selectedDisplayID = s.displayID
        cameraEnabled = s.cameraEnabled
        cameraID = s.cameraID
        micEnabled = s.micEnabled
        micID = s.micID
        systemAudioEnabled = s.systemAudio
        cameraShape = s.cameraShape
        roundness = s.roundness
        mirrorCamera = s.mirror
        border = s.border
        shadow = s.shadow
        smoothTransitions = s.smooth
        screenFit = s.screenFit
        cameraPlacement = s.cameraPlacement
        screenPlacement = s.screenPlacement
        resolution = s.resolution
        aspect = s.aspect
        fps = s.fps
        codec = s.codec
        quality = s.quality
        showsCursor = s.cursor
        if let f = s.folder { saveFolder = URL(fileURLWithPath: f, isDirectory: true) }
        openExportAfterRecording = s.exportAfter
        previewVisible = s.preview
        previewOnTop = s.previewOnTop
    }

    private func save() {
        let s = StoredSettings(
            mode: mode, screenKind: screenKind, displayID: selectedDisplayID, cameraEnabled: cameraEnabled,
            cameraID: cameraID, micEnabled: micEnabled, micID: micID, systemAudio: systemAudioEnabled,
            cameraShape: cameraShape, roundness: roundness, mirror: mirrorCamera, border: border, shadow: shadow,
            smooth: smoothTransitions, screenFit: screenFit, cameraPlacement: cameraPlacement,
            screenPlacement: screenPlacement, resolution: resolution, aspect: aspect, fps: fps, codec: codec,
            quality: quality, cursor: showsCursor, folder: saveFolder.path, exportAfter: openExportAfterRecording,
            preview: previewVisible, previewOnTop: previewOnTop)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}
