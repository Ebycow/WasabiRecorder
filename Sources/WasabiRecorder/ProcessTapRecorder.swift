import AVFoundation
import CoreAudio
import os

/// Collects per-bin peak levels from the capture queue for the UI to drain.
final class PeakMeter: @unchecked Sendable {
    let framesPerPeak: Int

    private struct State {
        var pending: [Float] = []
        var binPeak: Float = 0
        var binFrames = 0
        var totalFrames: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(framesPerPeak: Int) {
        self.framesPerPeak = max(1, framesPerPeak)
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        nonisolated(unsafe) let channels = channelData
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let framesPerPeak = framesPerPeak

        state.withLock { s in
            for frame in 0..<frames {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    let sample = interleaved
                        ? channels[0][frame * stride + channel]
                        : channels[channel][frame]
                    peak = max(peak, abs(sample))
                }
                s.binPeak = max(s.binPeak, peak)
                s.binFrames += 1
                if s.binFrames == framesPerPeak {
                    s.pending.append(min(s.binPeak, 1))
                    s.binPeak = 0
                    s.binFrames = 0
                }
            }
            s.totalFrames += Int64(frames)
        }
    }

    func drain() -> (peaks: [Float], totalFrames: Int64) {
        state.withLock { s in
            defer { s.pending.removeAll(keepingCapacity: true) }
            return (s.pending, s.totalFrames)
        }
    }
}

/// A running capture that writes to a file and feeds a peak meter.
protocol CaptureRecorder: AnyObject {
    var format: AVAudioFormat? { get }
    var meter: PeakMeter? { get }
    func stop()
}

/// Writes captured audio to disk on the capture queue. Taps only deliver audio
/// while the tapped app is producing sound, so stalls are filled with silence
/// to keep the recording on the wall-clock timeline.
final class CaptureSink: @unchecked Sendable {
    let format: AVAudioFormat
    let meter: PeakMeter
    private let file: AVAudioFile
    private let silence: AVAudioPCMBuffer
    private let tapBuffers: UnsafeMutableAudioBufferListPointer
    private let stallTicks: UInt64
    private var writtenUntil: UInt64

    init(file: AVAudioFile, format: AVAudioFormat, meter: PeakMeter, start: UInt64) {
        self.file = file
        self.format = format
        self.meter = meter
        writtenUntil = start
        stallTicks = AudioConvertNanosToHostTime(150_000_000)

        silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 10))!
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        tapBuffers = AudioBufferList.allocate(maximumBuffers: format.isInterleaved ? 1 : Int(format.channelCount))
    }

    deinit {
        free(tapBuffers.unsafeMutablePointer)
    }

    /// IO callback. The tap's streams come last in the aggregate's input list.
    func receive(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard source.count >= tapBuffers.count else { return }
        for index in 0..<tapBuffers.count {
            tapBuffers[index] = source[source.count - tapBuffers.count + index]
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapBuffers.unsafePointer, deallocator: nil) else { return }
        deliver(buffer, at: time)
    }

    /// Writes `buffer`, first filling any stall since the previous one.
    func deliver(_ buffer: AVAudioPCMBuffer, at time: AudioTimeStamp) {
        guard buffer.frameLength > 0 else { return }
        let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : AudioGetCurrentHostTime()
        if host > writtenUntil { padSilence(ticks: host - writtenUntil) }
        write(buffer)
        writtenUntil = max(writtenUntil, host + ticks(frames: buffer.frameLength))
    }

    /// Called periodically (and at stop) to cover silence while no audio arrives.
    func catchUp(force: Bool = false) {
        let now = AudioGetCurrentHostTime()
        guard now > writtenUntil, force || now - writtenUntil > stallTicks else { return }
        padSilence(ticks: now - writtenUntil, minimum: 0)
        writtenUntil = now
    }

    func close() {
        file.close()
    }

    private func padSilence(ticks gap: UInt64, minimum: UInt64? = nil) {
        // Small gaps are scheduling jitter, not silence.
        guard gap > (minimum ?? stallTicks) else { return }
        var frames = AVAudioFrameCount(Double(AudioConvertHostTimeToNanos(gap)) / 1e9 * format.sampleRate)
        while frames > 0 {
            silence.frameLength = min(frames, silence.frameCapacity)
            write(silence)
            frames -= silence.frameLength
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
        meter.ingest(buffer)
    }

    private func ticks(frames: AVAudioFrameCount) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64(Double(frames) / format.sampleRate * 1e9))
    }
}

/// Records the mixed output of a set of processes through a private Core Audio
/// process tap. Nothing is muted: the app keeps playing through the speakers.
final class ProcessTapRecorder: CaptureRecorder {
    let fileURL: URL
    var format: AVAudioFormat? { sink?.format }
    var meter: PeakMeter? { sink?.meter }

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var sink: CaptureSink?
    private var silenceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "WasabiRecorder.capture", qos: .userInitiated)
    private var isStopped = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        stop()
    }

    func start(processObjectIDs: [AudioObjectID]) throws {
        do {
            try startThrowing(processObjectIDs)
        } catch {
            stop()
            throw error
        }
    }

    private func startThrowing(_ processObjectIDs: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Wasabi Recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isProcessRestoreEnabled = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "タップの作成")

        var streamDescription = try tapID.get(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "フォーマットの取得")
        }

        // Tap-only aggregate: adding the output device as a sub-device would also
        // open its inputs (audio interfaces, mics) and mix them into the buffers.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wasabi Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "集約デバイスの作成")

        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )

        // ~100 peaks per second regardless of the device rate.
        let meter = PeakMeter(framesPerPeak: Int(format.sampleRate / 100))
        let sink = CaptureSink(file: file, format: format, meter: meter, start: AudioGetCurrentHostTime())
        self.sink = sink

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
            sink.receive(input, at: inputTime.pointee)
        }, "IOProc の作成")

        try check(AudioDeviceStart(aggregateID, ioProcID), "録音の開始")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(50))
        timer.setEventHandler { sink.catchUp() }
        timer.resume()
        silenceTimer = timer
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        silenceTimer?.cancel()
        silenceTimer = nil
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if let sink {
            queue.sync {
                sink.catchUp(force: true)
                sink.close()
            }
        }
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }
}
