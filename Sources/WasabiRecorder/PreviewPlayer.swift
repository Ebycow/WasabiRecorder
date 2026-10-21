import AVFoundation

/// Plays a segment of the recording with the export gain applied, so the
/// preview sounds like the saved file. The engine only runs while playing.
final class PreviewPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let gainUnit = AVAudioUnitEQ(numberOfBands: 0)
    private let file: AVAudioFile
    private var segment: ClosedRange<TimeInterval> = 0...0

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        engine.attach(node)
        engine.attach(gainUnit)
        engine.connect(node, to: gainUnit, format: file.processingFormat)
        engine.connect(gainUnit, to: engine.mainMixerNode, format: file.processingFormat)
    }

    /// AVAudioUnitEQ's global gain tops out at +24 dB.
    static let gainRange: ClosedRange<Double> = -12...24

    var gainDB: Double = 0 {
        didSet { gainUnit.globalGain = Float(gainDB.clamped(to: Self.gainRange)) }
    }

    var isPlaying: Bool { node.isPlaying }

    /// Position in the recording, or nil once the scheduled segment has ended.
    var currentTime: TimeInterval? {
        guard node.isPlaying,
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return nil }
        let time = segment.lowerBound + Double(playerTime.sampleTime) / playerTime.sampleRate
        return time < segment.upperBound ? time : nil
    }

    func play(from start: TimeInterval, to end: TimeInterval) throws {
        node.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, min(file.length - startFrame, AVAudioFramePosition((end - start) * sampleRate))))
        guard frameCount > 0 else { return }
        segment = start...end
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
