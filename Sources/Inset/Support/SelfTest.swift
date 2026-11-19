import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// `Inset --selftest <dir>` renders synthetic screen + camera sources through the real
/// compositor, animator, encoder and audio mixdown, then writes a movie and PNG stills.
/// Needs no permissions, so it doubles as a CI-style smoke test.
enum SelfTest {
    static func run(outputDirectory: URL) {
        let done = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            do {
                try await runAsync(outputDirectory)
            } catch {
                print("SELFTEST FAILED: \(error.localizedDescription)")
                failed = true
            }
            done.signal()
        }
        done.wait()
        exit(failed ? 1 : 0)
    }

    private static func check(_ cond: Bool, _ msg: String) throws {
        if !cond { throw InsetError.message(msg) }
        print("  ✓ \(msg)")
    }

    private static func runAsync(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("Geometry")
        let canvas = CGSize(width: 1920, height: 1080)
        let crop = ScreenSource.pixelCrop(CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2, contentScale: 1, buffer: CGSize(width: 1600, height: 1200))
        try check(crop == CGRect(x: 0, y: 0, width: 1600, height: 1200), "content rect in points → pixels")
        let crop2 = ScreenSource.pixelCrop(CGRect(x: 0, y: 0, width: 1600, height: 1200), scale: 2, contentScale: 1, buffer: CGSize(width: 1600, height: 1200))
        try check(crop2 == CGRect(x: 0, y: 0, width: 1600, height: 1200), "content rect already in pixels")
        let o = Geometry.overlayRect(Placement(cx: 0.99, cy: 0.99, width: 0.2), aspect: 1, canvas: canvas)
        try check(o.maxX <= canvas.width && o.maxY <= canvas.height, "overlay clamped inside canvas")
        let r = Geometry.resized(.zero, anchor: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 900), aspect: 16 / 9, canvas: canvas)
        try check(abs(r.width / r.height - 16 / 9) < 0.01, "resize keeps aspect")

        print("Render + encode")
        let compositor = try Compositor()
        let url = dir.appendingPathComponent("selftest.mp4")
        let settings = RecordingSettings(url: url, canvas: canvas, fps: 30, codec: .hevc, quality: .high, microphone: true, systemAudio: true)
        let recorder = try Recorder(settings: settings)
        let animator = SceneAnimator()
        let screenSize = CGSize(width: 1920, height: 1200)
        let camSize = CGSize(width: 1280, height: 720)
        let base = CMClockGetTime(CMClockGetHostTimeClock())
        let fps = 30.0
        let seconds = 6.0
        var phaseA = 0.0, phaseB = 0.0
        var gpuTotal = 0.0

        for i in 0..<Int(seconds * fps) {
            let t = Double(i) / fps
            var layout = LayoutSnapshot()
            switch t {
            case ..<1.2: layout.mode = .screenWithCamera
            case ..<2.4: layout.mode = .cameraWithScreen
            case ..<3.6: layout.mode = .camera
            case ..<4.8: layout.mode = .screen
            default: layout.mode = .screenWithCamera; layout.cameraShape = .rectangle; layout.border = true
            }
            let screenPB = try makeScreen(size: screenSize, t: t, compositor: compositor)
            let camPB = try makeCamera(size: camSize, t: t, compositor: compositor)
            let host = base + CMTime(seconds: t, preferredTimescale: 600)
            let screen = SourceFrame(buffer: screenPB, crop: CGRect(origin: .zero, size: screenSize), hostTime: host)
            let camera = SourceFrame(buffer: camPB, crop: CGRect(origin: .zero, size: camSize), hostTime: host)
            let target = Geometry.target(layout, canvas: canvas, screenAspect: screen.aspect, cameraAspect: camera.aspect)
            let scene = animator.state(target: target, layout: layout, now: t)

            guard let out = compositor.makeOutputBuffer(size: canvas),
                  let (outTex, outCV) = compositor.texture(for: out),
                  let (sTex, sCV) = compositor.texture(for: screenPB),
                  let (cTex, cCV) = compositor.texture(for: camPB),
                  let cb = compositor.commandQueue.makeCommandBuffer() else { throw InsetError.message("GPU setup failed") }
            let inputs = Compositor.Inputs(screen: screen, camera: camera, screenTexture: sTex, cameraTexture: cTex)
            compositor.encode(scene: scene, layout: layout, canvas: canvas, inputs: inputs, into: outTex, commandBuffer: cb,
                              scale: 1, offset: .zero, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                cb.addCompletedHandler { _ in cont.resume() }
                cb.commit()
            }
            gpuTotal += cb.gpuEndTime - cb.gpuStartTime
            _ = (outCV, sCV, cCV)
            recorder.appendVideo(out, hostTime: host)

            let samples = Int(48_000 / fps)
            recorder.appendAudio(try tone(samples: samples, freq: 440, phase: &phaseA, pts: host), track: .microphone)
            recorder.appendAudio(try tone(samples: samples, freq: 660, phase: &phaseB, pts: host), track: .system)
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / fps / 2))
        }
        let avgGPU = gpuTotal / (seconds * fps) * 1000
        print(String(format: "  ✓ average GPU time per 1080p frame: %.2f ms", avgGPU))

        _ = try await recorder.finish()
        try await AudioMixdown.mixIfNeeded(url)

        print("Verify file")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try check(abs(duration - seconds) < 0.3, String(format: "duration %.2fs", duration))
        try check(video.count == 1, "one video track")
        try check(audio.count == 1, "mic + system audio mixed into one track")
        let size = try await video[0].load(.naturalSize)
        try check(size == canvas, "video is \(Int(size.width))×\(Int(size.height))")

        print("Stills")
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for (name, time) in [("1-screen+cam", 0.8), ("2-transition", 1.37), ("3-cam+screen", 2.0), ("4-camera", 3.2), ("5-screen", 4.4), ("6-rect-border", 5.6)] {
            let (img, _) = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let dest = dir.appendingPathComponent("\(name).png")
            if let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
            }
            print("  ✓ \(dest.lastPathComponent)")
        }
        print("SELFTEST PASSED → \(url.path)")
    }

    // MARK: Synthetic sources

    private static func makeBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { throw InsetError.message("buffer alloc failed") }
        return pb
    }

    private static func draw(_ pb: CVPixelBuffer, _ body: (CGContext, CGSize) -> Void) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body(ctx, CGSize(width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func makeScreen(size: CGSize, t: Double, compositor: Compositor) throws -> CVPixelBuffer {
        let pb = try makeBuffer(size)
        draw(pb) { ctx, s in
            ctx.setFillColor(NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: s))
            ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: s.width, height: 44))
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: 18 + CGFloat(i) * 26, y: 14, width: 16, height: 16))
            }
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black]
            ("Inset self-test" as NSString).draw(at: CGPoint(x: 80, y: 110), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor.darkGray]
            for line in 0..<18 {
                ("func render(frame: \(line)) -> Texture { compositor.encode(scene, into: output) }" as NSString)
                    .draw(at: CGPoint(x: 80, y: 220 + CGFloat(line) * 38), withAttributes: body)
            }
            let x = 200 + (s.width - 600) * CGFloat((sin(t * 2) + 1) / 2)
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: x, y: s.height - 180, width: 200, height: 100))
        }
        return pb
    }

    private static func makeCamera(size: CGSize, t: Double, compositor: Compositor) throws -> CVPixelBuffer {
        let pb = try makeBuffer(size)
        draw(pb) { ctx, s in
            let colors = [NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.35, alpha: 1).cgColor,
                          NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.45, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: s.width, y: s.height), options: [])
            let bob = CGFloat(sin(t * 3)) * 12
            ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.86, blue: 0.74, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: s.width / 2 - 130, y: s.height / 2 - 190 + bob, width: 260, height: 300))
            ctx.fillEllipse(in: CGRect(x: s.width / 2 - 260, y: s.height / 2 + 120 + bob, width: 520, height: 400))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: s.width / 2 - 60, y: s.height / 2 - 80 + bob, width: 22, height: 22))
            ctx.fillEllipse(in: CGRect(x: s.width / 2 + 38, y: s.height / 2 - 80 + bob, width: 22, height: 22))
            let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: NSColor.white]
            ("CAM ▸" as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: tag)
        }
        return pb
    }

    private static func tone(samples: Int, freq: Double, phase: inout Double, pts: CMTime) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var data = [Float](repeating: 0, count: samples * 2)
        for i in 0..<samples {
            let v = Float(sin(phase) * 0.2)
            data[i * 2] = v
            data[i * 2 + 1] = v
            phase += 2 * .pi * freq / 48_000
        }
        let bytes = data.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, let format else { throw InsetError.message("audio alloc failed") }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: samples, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        guard let sb else { throw InsetError.message("audio buffer failed") }
        return sb
    }
}

/// Debug aid: `INSET_SNAPSHOT=<dir>` renders every visible window to PNG after launch
/// (and `INSET_EXPORT_DEMO=<movie>` opens the export window for it first).
@MainActor
enum Snapshot {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["INSET_SNAPSHOT"] else { return }
        if let demo = env["INSET_EXPORT_DEMO"] { WindowManager.shared.showExport(URL(fileURLWithPath: demo)) }
        if env["INSET_PREVIEW_DEMO"] != nil { AppModel.shared.previewVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "\(i)-\(window.title.isEmpty ? "window" : window.title).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
            NSApp.terminate(nil)
        }
    }
}
