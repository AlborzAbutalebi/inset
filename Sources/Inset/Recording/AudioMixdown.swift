import AVFoundation

/// Mixes the microphone and system-audio tracks into one stereo track so every player
/// (including Photos on iPhone) hears both. Video is passed through untouched.
enum AudioMixdown {
    static func mixIfNeeded(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let allAudio = try await asset.loadTracks(withMediaType: .audio)
        guard allAudio.count > 1 else { return }
        var audioTracks: [AVAssetTrack] = []
        for track in allAudio {
            let range = try await track.load(.timeRange)
            if range.duration.seconds > 0.05 { audioTracks.append(track) }
        }
        guard !audioTracks.isEmpty, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-mix.mp4")
        try? FileManager.default.removeItem(at: tmp)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
        audioOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        reader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let hint = try await videoTrack.load(.formatDescriptions).first
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoIn.transform = try await videoTrack.load(.preferredTransform)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: Recorder.aacSettings)
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading() else { throw reader.error ?? InsetError.message("Couldn't read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? InsetError.message("Couldn't write the mix.") }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.run(output: videoOut, input: videoIn, label: "video") }
            group.addTask { await pump.run(output: audioOut, input: audioIn, label: "audio") }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? InsetError.message("Mixing failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? InsetError.message("Mixing failed.")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private final class Pump: @unchecked Sendable {
        func run(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String) async {
            let q = DispatchQueue(label: "app.inset.mix.\(label)")
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var done = false
                input.requestMediaDataWhenReady(on: q) {
                    while input.isReadyForMoreMediaData && !done {
                        if let sb = output.copyNextSampleBuffer() {
                            if !input.append(sb) { done = true }
                        } else {
                            done = true
                        }
                        if done {
                            input.markAsFinished()
                            cont.resume()
                        }
                    }
                }
            }
        }
    }
}
