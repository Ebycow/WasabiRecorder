import Accelerate
import AVFoundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case wav, m4a, mp3

    var contentType: UTType {
        switch self {
        case .wav: .wav
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        }
    }

    var label: String { rawValue.uppercased() }

    var summary: String {
        switch self {
        case .wav: "24 bit · 非圧縮"
        case .m4a: "AAC 256 kbps"
        case .mp3: "約 190 kbps · 容量小"
        }
    }
}

/// Destination for rendered buffers: an `AVAudioFile`, or `MP3Writer` for
/// the format Core Audio cannot encode.
protocol AudioSink: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
    func finish() throws
}

extension AVAudioFile: AudioSink {
    func finish() throws { close() }
}

enum Exporter {
    /// Writes `range` (seconds) of `source` to `destination` with `gain`
    /// applied (hard-limited to full scale), and a few milliseconds of fade at
    /// each cut so trims never click.
    static func export(from source: URL, range: ClosedRange<Double>, gain: Float = 1, to destination: URL, format: ExportFormat) throws {
        let input = try AVAudioFile(forReading: source)
        let processing = input.processingFormat
        let sampleRate = processing.sampleRate
        let channels = Int(processing.channelCount)

        let startFrame = max(0, AVAudioFramePosition((range.lowerBound * sampleRate).rounded()))
        let endFrame = min(input.length, AVAudioFramePosition((range.upperBound * sampleRate).rounded()))
        let totalFrames = endFrame - startFrame
        guard totalFrames > 0 else { return }

        let settings: [String: Any] = switch format {
        case .wav: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        case .m4a: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(sampleRate, 48_000),
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 256_000,
        ]
        case .mp3: [:]
        }

        try? FileManager.default.removeItem(at: destination)
        let output: any AudioSink = if format == .mp3 {
            try MP3Writer(url: destination, sampleRate: sampleRate, channels: channels)
        } else {
            try AVAudioFile(
                forWriting: destination,
                settings: settings,
                commonFormat: processing.commonFormat,
                interleaved: processing.isInterleaved
            )
        }

        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: chunk) else { return }
        let fadeFrames = min(Int(sampleRate * 0.004), Int(totalFrames / 2))

        input.framePosition = startFrame
        var written: AVAudioFramePosition = 0
        while written < totalFrames {
            let request = AVAudioFrameCount(min(AVAudioFramePosition(chunk), totalFrames - written))
            try input.read(into: buffer, frameCount: request)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            applyGain(buffer, gain)
            applyEdgeFades(buffer, offset: Int(written), total: Int(totalFrames), fadeFrames: fadeFrames)
            try output.write(from: buffer)
            written += AVAudioFramePosition(count)
        }
        try output.finish()
    }

    private static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) {
        guard gain != 1, let data = buffer.floatChannelData else { return }
        let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samples = vDSP_Length(Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1))
        var gain = gain, low: Float = -1, high: Float = 1
        for plane in 0..<planes {
            vDSP_vsmul(data[plane], 1, &gain, data[plane], 1, samples)
            vDSP_vclip(data[plane], 1, &low, &high, data[plane], 1, samples)
        }
    }

    private static func applyEdgeFades(_ buffer: AVAudioPCMBuffer, offset: Int, total: Int, fadeFrames: Int) {
        guard fadeFrames > 0, let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard offset < fadeFrames || offset + count > total - fadeFrames else { return }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride

        for frame in 0..<count {
            let position = offset + frame
            let distance = min(position, total - 1 - position)
            guard distance < fadeFrames else { continue }
            let gain = Float(distance) / Float(fadeFrames)
            for channel in 0..<channels {
                if interleaved {
                    data[0][frame * stride + channel] *= gain
                } else {
                    data[channel][frame] *= gain
                }
            }
        }
    }
}
