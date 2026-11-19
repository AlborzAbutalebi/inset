import AVFoundation
import CoreMedia
import VideoToolbox

enum VideoCodec: String, CaseIterable, Codable {
    case hevc, h264
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

enum Quality: String, CaseIterable, Codable {
    case standard, high
    var label: String { self == .standard ? "Standard" : "High" }
    var multiplier: Double { self == .standard ? 1.0 : 1.75 }
}

struct RecordingSettings {
    var url: URL
    var canvas: CGSize
    var fps: Int
    var codec: VideoCodec
    var quality: Quality
    var microphone: Bool
    var systemAudio: Bool
}

/// Hardware-encodes the composited canvas plus up to two audio tracks.
/// All timing is normalised so the file starts at zero and pauses leave no gaps.
final class Recorder: @unchecked Sendable {
    enum Track { case microphone, system }

    let settings: RecordingSettings
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let micInput: AVAssetWriterInput?
    private let systemInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "app.inset.writer", qos: .userInitiated)

    private let lock = UnfairLock()
    private var _paused = false
    private var _finishing = false

    // writer-queue only
    private var timeBase: CMTime?
    private var pauseOffset = CMTime.zero
    private var pauseStart: CMTime?
    private var lastVideoPTS = CMTime.negativeInfinity
    private var lastAudioEnd: [Track: CMTime] = [:]
    private var frameCount = 0
    private var failure: Error?

    /// Delay applied to audio so it lines up with (slightly older) video frames.
    var audioDelay = CMTime.zero

    init(settings: RecordingSettings) throws {
        self.settings = settings
        try? FileManager.default.removeItem(at: settings.url)
        writer = try AVAssetWriter(outputURL: settings.url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        let w = Int(settings.canvas.width), h = Int(settings.canvas.height)
        let pixelsPerSecond = Double(w * h * settings.fps)
        let bitsPerPixel = settings.codec == .hevc ? 0.08 : 0.13
        let bitrate = Int(pixelsPerSecond * bitsPerPixel * settings.quality.multiplier)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        } else {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw InsetError.message("Can't create the video track.") }
        writer.add(videoInput)

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = true
            return input
        }
        micInput = settings.microphone ? audioInput() : nil
        systemInput = settings.systemAudio ? audioInput() : nil
        for input in [micInput, systemInput].compactMap({ $0 }) where writer.canAdd(input) { writer.add(input) }

        guard writer.startWriting() else {
            throw writer.error ?? InsetError.message("Can't start writing the recording.")
        }
        writer.startSession(atSourceTime: .zero)
    }

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    var acceptsVideo: Bool { lock.withLock { !_paused && !_finishing } }
    var isPaused: Bool { lock.withLock { _paused } }
    var hasAudioTracks: Int { (micInput == nil ? 0 : 1) + (systemInput == nil ? 0 : 1) }

    /// Seconds of recorded media so far (excluding pauses).
    var duration: Double {
        queue.sync {
            lastVideoPTS.isNumeric ? lastVideoPTS.seconds : 0
        }
    }

    func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock { _paused = true }
        queue.async { [self] in if pauseStart == nil { pauseStart = now } }
    }

    func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if let start = pauseStart {
                pauseOffset = pauseOffset + (now - start)
                pauseStart = nil
            }
            lock.withLock { _paused = false }
        }
    }

    func appendVideo(_ buffer: CVPixelBuffer, hostTime: CMTime) {
        queue.async { [self] in
            guard writer.status == .writing, pauseStart == nil, !lock.withLock({ _finishing }) else { return }
            if timeBase == nil { timeBase = hostTime }
            guard let base = timeBase else { return }
            let pts = hostTime - base - pauseOffset
            guard pts > lastVideoPTS, videoInput.isReadyForMoreMediaData else { return }
            if adaptor.append(buffer, withPresentationTime: pts) {
                lastVideoPTS = pts
                frameCount += 1
            } else {
                failure = writer.error
            }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: Track) {
        queue.async { [self] in
            guard writer.status == .writing, pauseStart == nil, let base = timeBase,
                  !lock.withLock({ _finishing }) else { return }
            guard let input = (track == .microphone ? micInput : systemInput) else { return }
            let offset = CMTimeSubtract(audioDelay, CMTimeAdd(base, pauseOffset))
            let start = sample.presentationTimeStamp + offset
            guard start >= .zero else { return }
            if let end = lastAudioEnd[track], start < end - CMTime(value: 1, timescale: 1000) { return }
            guard input.isReadyForMoreMediaData, let retimed = sample.retimed(by: offset) else { return }
            if input.append(retimed) {
                lastAudioEnd[track] = start + sample.duration
            }
        }
    }

    /// Finishes the file. Returns the URL and how many audio tracks it contains.
    func finish() async throws -> URL {
        lock.withLock { _finishing = true }
        let writer = self.writer
        let inputs = [videoInput, micInput, systemInput].compactMap { $0 }
        let frames: Int = await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: frameCount) }
        }
        guard frames > 0 else {
            writer.cancelWriting()
            throw InsetError.message("Nothing was recorded.")
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                inputs.forEach { $0.markAsFinished() }
                if writer.status == .writing {
                    writer.finishWriting { cont.resume() }
                } else {
                    cont.resume()
                }
            }
        }
        if writer.status != .completed {
            throw writer.error ?? failure ?? InsetError.message("The recording couldn't be saved.")
        }
        return settings.url
    }
}

extension CMSampleBuffer {
    func retimed(by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<count {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + offset
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
