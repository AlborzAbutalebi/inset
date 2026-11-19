import Accelerate
import AVFoundation
import QuartzCore

/// Webcam capture (built-in, external, Continuity Camera). Delivers BGRA IOSurface frames.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((SourceFrame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "app.inset.camera.session")
    private let frameQueue = DispatchQueue(label: "app.inset.camera.frames", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    private(set) var deviceID: String?

    override init() {
        super.init()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start(deviceID: String, targetHeight: Int, fps: Int) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(deviceID: deviceID, targetHeight: targetHeight, fps: fps)
                    if !session.isRunning { session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                cont.resume()
            }
        }
    }

    private func configure(deviceID: String, targetHeight: Int, fps: Int) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw InsetError.message("Camera not found.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if self.deviceID != deviceID || input == nil {
            if let input { session.removeInput(input) }
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else { throw InsetError.message("Camera is busy.") }
            session.addInput(newInput)
            input = newInput
            self.deviceID = deviceID
        }
        if let format = Self.bestFormat(device, targetHeight: targetHeight, fps: Double(fps)) {
            try device.lockForConfiguration()
            device.activeFormat = format
            let supportsFPS = format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) - 0.5 }
            if supportsFPS {
                let d = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = d
                device.activeVideoMaxFrameDuration = d
            }
            device.unlockForConfiguration()
        }
    }

    static func bestFormat(_ device: AVCaptureDevice, targetHeight: Int, fps: Double) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { f in
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps - 0.5 }
        }
        let pool = usable.isEmpty ? device.formats : usable
        return pool.min { a, b in
            score(a, targetHeight) < score(b, targetHeight)
        }
    }

    private static func score(_ f: AVCaptureDevice.Format, _ target: Int) -> Int {
        let h = Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).height)
        // Prefer the smallest format at or above the target; penalise going below it.
        return h >= target ? h - target : (target - h) * 4
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = sb.imageBuffer else { return }
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let host = CMSyncConvertTime(sb.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        let crop = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        onFrame?(SourceFrame(buffer: pb, crop: crop, hostTime: host))
    }
}

/// Microphone capture, delivered as 48 kHz stereo float PCM ready for the AAC encoder.
final class MicSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSample: ((CMSampleBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "app.inset.mic.session")
    private let sampleQueue = DispatchQueue(label: "app.inset.mic.samples", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private(set) var deviceID: String?
    private var lastLevel: CFTimeInterval = 0
    private var peak: Float = 0

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    if self.deviceID != deviceID || input == nil {
                        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw InsetError.message("Microphone not found.") }
                        session.beginConfiguration()
                        if let input { session.removeInput(input) }
                        let newInput = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(newInput) { session.addInput(newInput) }
                        session.commitConfiguration()
                        input = newInput
                        self.deviceID = deviceID
                    }
                    if !session.isRunning { session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                cont.resume()
            }
        }
        onLevel?(0)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let host = CMSyncConvertTime(sb.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        let delta = host - sb.presentationTimeStamp
        let buffer = abs(delta.seconds) > 0.000_001 ? (sb.retimed(by: delta) ?? sb) : sb
        onSample?(buffer)
        meter(sb)
    }

    private func meter(_ sb: CMSampleBuffer) {
        guard onLevel != nil else { return }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = abl.mBuffers.mData else { return }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        var m: Float = 0
        vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(count))
        peak = max(peak, m)
        let now = CACurrentMediaTime()
        if now - lastLevel > 1.0 / 24 {
            lastLevel = now
            onLevel?(peak)
            peak = 0
        }
    }
}
