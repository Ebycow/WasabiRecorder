import AVFoundation
import CoreAudio

/// Records one (mono) or two (stereo) channels of an input device, e.g. just
/// the mic on input 1 of a multi-channel audio interface.
final class InputDeviceRecorder: CaptureRecorder {
    let fileURL: URL
    var format: AVAudioFormat? { sink?.format }
    var meter: PeakMeter? { sink?.meter }

    private let deviceID: AudioObjectID
    private let channels: [Int]
    private var ioProcID: AudioDeviceIOProcID?
    private var sink: CaptureSink?
    private let queue = DispatchQueue(label: "WasabiRecorder.input", qos: .userInitiated)
    private var isStopped = false

    init(fileURL: URL, deviceID: AudioObjectID, channels: [Int]) {
        self.fileURL = fileURL
        self.deviceID = deviceID
        self.channels = channels
    }

    deinit {
        stop()
    }

    func start() throws {
        do {
            try startThrowing()
        } catch {
            stop()
            throw error
        }
    }

    private func startThrowing() throws {
        let sampleRate = try deviceID.get(kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "入力フォーマットの取得")
        }

        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let meter = PeakMeter(framesPerPeak: Int(sampleRate / 100))
        let sink = CaptureSink(file: file, format: format, meter: meter, start: AudioGetCurrentHostTime())
        self.sink = sink

        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let destination = scratch.floatChannelData else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "バッファの確保")
        }
        let channels = channels

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, queue) { _, input, inputTime, _, _ in
            let streams = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = streams.first, first.mNumberChannels > 0 else { return }
            let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), Int(scratch.frameCapacity))

            for (output, wanted) in channels.enumerated() {
                // Device channels are numbered across all input streams.
                var base = 0
                for stream in streams {
                    let count = Int(stream.mNumberChannels)
                    if wanted < base + count, let data = stream.mData?.assumingMemoryBound(to: Float.self) {
                        let offset = wanted - base
                        for frame in 0..<frames {
                            destination[output][frame] = data[frame * count + offset]
                        }
                        break
                    }
                    base += count
                }
            }
            scratch.frameLength = AVAudioFrameCount(frames)
            sink.deliver(scratch, at: inputTime.pointee)
        }, "IOProc の作成")

        try check(AudioDeviceStart(deviceID, ioProcID), "録音の開始")
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            self.ioProcID = nil
        }
        if let sink {
            queue.sync {
                sink.catchUp(force: true)
                sink.close()
            }
        }
    }
}
