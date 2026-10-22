import AVFoundation
import CLame

struct MP3Error: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? { "MP3 の\(operation)に失敗しました (\(code))" }
}

/// Encodes float PCM buffers (mono or stereo) to an MP3 file with LAME.
/// VBR -V 2 (~190 kbps): transparent for most material at under a tenth of
/// the size of 24-bit WAV.
final class MP3Writer: AudioSink {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let channels: Int
    private var output = [UInt8]()

    init(url: URL, sampleRate: Double, channels: Int) throws {
        guard (1...2).contains(channels) else { throw MP3Error(operation: "チャンネル設定", code: Int32(channels)) }
        guard let lame = lame_init() else { throw MP3Error(operation: "初期化", code: -1) }
        lame_set_in_samplerate(lame, Int32(sampleRate.rounded()))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_VBR(lame, vbr_default)
        lame_set_VBR_quality(lame, 2)
        let status = lame_init_params(lame)
        guard status >= 0 else {
            lame_close(lame)
            throw MP3Error(operation: "初期化", code: status)
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            lame_close(lame)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        self.lame = lame
        self.handle = handle
        self.channels = channels
    }

    deinit {
        lame_close(lame)
        try? handle.close()
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int32(buffer.frameLength)
        // Worst case from lame.h: 1.25 * samples + 7200.
        reserve(Int(frames) * 5 / 4 + 7200)
        let size = Int32(output.count)
        let count = output.withUnsafeMutableBufferPointer { out in
            if buffer.format.isInterleaved && channels == 2 {
                lame_encode_buffer_interleaved_ieee_float(lame, data[0], frames, out.baseAddress, size)
            } else {
                // Mono ignores the right channel; interleaved mono is contiguous.
                lame_encode_buffer_ieee_float(lame, data[0], data[channels - 1], frames, out.baseAddress, size)
            }
        }
        try append(count, operation: "エンコード")
    }

    func finish() throws {
        reserve(7200)
        let count = output.withUnsafeMutableBufferPointer {
            lame_encode_flush(lame, $0.baseAddress, Int32($0.count))
        }
        try append(count, operation: "エンコード")

        // The first frame is a placeholder for the VBR (Xing/LAME) header that
        // lets players show the right duration and seek accurately.
        let tagSize = output.withUnsafeMutableBufferPointer {
            lame_get_lametag_frame(lame, $0.baseAddress, $0.count)
        }
        if tagSize > 0, tagSize <= output.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: output[..<tagSize])
        }
        try handle.close()
    }

    private func reserve(_ size: Int) {
        if output.count < size { output = [UInt8](repeating: 0, count: size) }
    }

    private func append(_ count: Int32, operation: String) throws {
        guard count >= 0 else { throw MP3Error(operation: operation, code: count) }
        try handle.write(contentsOf: output[..<Int(count)])
    }
}
