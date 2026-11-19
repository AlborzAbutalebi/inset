import CoreMedia
import ScreenCaptureKit

/// Captures a display or a single window with ScreenCaptureKit (GPU-scaled, zero-copy IOSurfaces).
final class ScreenSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onVideo: ((SourceFrame) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "app.inset.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.inset.screen.audio", qos: .userInitiated)
    private let lock = UnfairLock()
    private var _isWindow = false

    var isRunning: Bool { stream != nil }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration, isWindow: Bool) async throws {
        await stop()
        lock.withLock { _isWindow = isWindow }
        let s = SCStream(filter: filter, configuration: configuration, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s
    }

    func update(filter: SCContentFilter, isWindow: Bool) async throws {
        guard let stream else { return }
        lock.withLock { _isWindow = isWindow }
        try await stream.updateContentFilter(filter)
    }

    func update(configuration: SCStreamConfiguration) async throws {
        try await stream?.updateConfiguration(configuration)
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    static func configuration(pixelSize: CGSize, fps: Int, showsCursor: Bool, captureAudio: Bool) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let size = Geometry.evenSize(pixelSize)
        c.width = Int(size.width)
        c.height = Int(size.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 6
        c.showsCursor = showsCursor
        c.scalesToFit = true
        c.ignoreShadowsSingleWindow = true
        c.capturesAudio = captureAudio
        c.sampleRate = 48_000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        return c
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen: handleVideo(sb)
        case .audio: onAudio?(sb)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream === stream { self.stream = nil }
        onStop?(error)
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = sb.imageBuffer else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        var crop = CGRect(origin: .zero, size: size)
        if lock.withLock({ _isWindow }),
           let dict = attachments[.contentRect],
           let rect = CGRect(dictionaryRepresentation: dict as! CFDictionary) {
            let scale = attachments[.scaleFactor] as? CGFloat ?? 1
            let contentScale = attachments[.contentScale] as? CGFloat ?? 1
            crop = Self.pixelCrop(rect, scale: scale, contentScale: contentScale, buffer: size)
        }
        onVideo?(SourceFrame(buffer: pb, crop: crop, hostTime: sb.presentationTimeStamp))
    }

    /// Converts the frame's content rect to buffer pixels, tolerating the differing unit
    /// conventions ScreenCaptureKit has used across macOS releases.
    static func pixelCrop(_ r: CGRect, scale: CGFloat, contentScale: CGFloat, buffer: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: buffer)
        for k in [scale, scale * contentScale, 1] where k > 0 {
            let c = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
            if c.width >= 16, c.height >= 16,
               c.maxX <= buffer.width * 1.02 + 1, c.maxY <= buffer.height * 1.02 + 1 {
                let out = c.intersection(bounds).integral
                return out.width >= 16 && out.height >= 16 ? out : bounds
            }
        }
        return bounds
    }
}
