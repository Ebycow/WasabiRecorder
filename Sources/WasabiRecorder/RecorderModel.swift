import AppKit
import AVFoundation
import Observation
import SwiftUI

enum Phase {
    case idle, recording, editing
}

/// What gets recorded: one app's output, or channels of an input device.
enum RecordingSource: Equatable {
    case app(AppIdentity)
    case input(InputSelection)

    var name: String {
        switch self {
        case .app(let app): app.name
        case .input(let input): input.deviceName
        }
    }
}

enum PanelLayout {
    /// Transparent room around the glass for its shadow and spring overshoot.
    static let margin: CGFloat = 28
    static let editorPadding: CGFloat = 12

    static func size(for phase: Phase) -> CGSize {
        switch phase {
        case .idle: CGSize(width: 100, height: 52)
        case .recording: CGSize(width: 340, height: 60)
        case .editing: CGSize(width: 372, height: 134)
        }
    }

    static func cornerRadius(for phase: Phase) -> CGFloat {
        switch phase {
        case .idle: 26
        case .recording: 30
        case .editing: 26
        }
    }
}

/// Implemented by the window controller: the glass window is resized to cover
/// the whole animation first, and shrunk to fit once the spring settles.
@MainActor
protocol PanelHost: AnyObject {
    func beginTransition(covering size: CGSize)
    func endTransition(at size: CGSize)
}

@MainActor
@Observable
final class RecorderModel {
    private(set) var phase: Phase = .idle
    var anchor: Alignment = .topLeading
    private(set) var source: RecordingSource?

    private(set) var peaks: [Float] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var selection: ClosedRange<Double> = 0...0
    private(set) var playhead: TimeInterval?
    private(set) var isPlaying = false
    private(set) var isSaving = false
    private(set) var didSave = false
    /// Briefly true after the recording was dropped into another app.
    private(set) var dropConfirmed = false
    /// The current recording already lives somewhere outside the app.
    private(set) var wasDelivered = false
    private(set) var discardArmed = false
    /// Loudest peak so far; the live waveform scales itself to it.
    private(set) var livePeak: Float = 0
    /// Export gain. Auto keeps the selection's peak at -1 dBFS.
    private(set) var gainDB: Double = 0
    private(set) var isAutoGain = true

    static let minimumSelection: TimeInterval = 0.05
    static let gainRange = PreviewPlayer.gainRange
    private static let autoGainTarget: Float = 0.891 // -1 dBFS

    var gainLinear: Float { Float(pow(10, gainDB / 20)) }
    var liveDisplayGain: Float { 0.9 / max(livePeak, 0.02) }

    @ObservationIgnored weak var host: PanelHost?
    /// Right-click menu for the panel, supplied by the app delegate.
    @ObservationIgnored var contextMenu: (() -> NSMenu)?
    @ObservationIgnored private var recorder: CaptureRecorder?
    @ObservationIgnored private var sampleRate: Double = 48_000
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var player: PreviewPlayer?
    @ObservationIgnored private var peaksPerSecond: Double = 100
    @ObservationIgnored private var playbackTimer: Timer?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingDate = Date()
    @ObservationIgnored private var transitionToken = 0
    @ObservationIgnored private var discardReset: Task<Void, Never>?
    @ObservationIgnored private var overviewCache: (bars: Int, values: [Float])?
    @ObservationIgnored private var dragExport: DragExport?
    @ObservationIgnored private var dropConfirmReset: Task<Void, Never>?

    private struct DragExport {
        let range: ClosedRange<Double>
        let gain: Float
        let format: ExportFormat
        let url: URL
    }

    /// Dragged files must outlive the session: apps like Ableton Live keep
    /// referencing the dropped file in place.
    private static let dragDirectory = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "Wasabi Recorder", directoryHint: .isDirectory)

    private static let selectedAppKey = "selectedBundleID"
    private static let selectedInputKey = "selectedInput"
    private static let exportFormatKey = "exportFormat"
    private static let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: "WasabiRecorder", directoryHint: .isDirectory)

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.selectedInputKey),
           let input = try? JSONDecoder().decode(InputSelection.self, from: data) {
            source = .input(input)
        } else if let bundleID = defaults.string(forKey: Self.selectedAppKey), let app = AppIdentity(bundleID: bundleID) {
            source = .app(app)
        }
        try? FileManager.default.removeItem(at: Self.temporaryDirectory)
    }

    var hasUnsavedWork: Bool { phase == .recording || (phase == .editing && !wasDelivered) }

    // MARK: - Phase transitions

    private func transition(to next: Phase) {
        guard next != phase else { return }
        let from = PanelLayout.size(for: phase)
        let to = PanelLayout.size(for: next)
        // Leave headroom for the spring's overshoot when growing.
        let cover = CGSize(
            width: max(from.width, to.width) + max(0, to.width - from.width) * 0.2,
            height: max(from.height, to.height) + max(0, to.height - from.height) * 0.2
        )
        transitionToken &+= 1
        let token = transitionToken
        host?.beginTransition(covering: cover)
        withAnimation(.spring(duration: 0.55, bounce: 0.32)) {
            phase = next
        } completion: { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.host?.endTransition(at: to)
        }
    }

    // MARK: - Source

    func chooseSource(thenRecord: Bool = false) {
        guard phase == .idle else { return }
        SourcePicker.present(apps: AudioApps.current(), inputs: AudioInputs.current(), selected: source) { [weak self] picked in
            guard let self else { return }
            self.select(picked)
            if thenRecord { self.startRecording() }
        }
    }

    private func select(_ newSource: RecordingSource) {
        source = newSource
        let defaults = UserDefaults.standard
        switch newSource {
        case .app(let app):
            defaults.set(app.bundleID, forKey: Self.selectedAppKey)
            defaults.removeObject(forKey: Self.selectedInputKey)
        case .input(let input):
            defaults.set(try? JSONEncoder().encode(input), forKey: Self.selectedInputKey)
        }
    }

    // MARK: - Recording

    func recordButtonTapped() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .editing: break
        }
    }

    private func startRecording() {
        guard phase == .idle else { return }
        guard let source else {
            chooseSource(thenRecord: true)
            return
        }

        try? FileManager.default.createDirectory(at: Self.temporaryDirectory, withIntermediateDirectories: true)
        let url = Self.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
        let recorder: CaptureRecorder

        do {
            switch source {
            case .app(let app):
                guard let target = AudioApps.current().first(where: { $0.matches(app) }) else {
                    chooseSource(thenRecord: true)
                    return
                }
                select(.app(target.identity))
                let tap = ProcessTapRecorder(fileURL: url)
                try tap.start(processObjectIDs: target.processObjectIDs)
                recorder = tap

            case .input(let input):
                guard let deviceID = AudioInputs.device(uid: input.deviceUID) else {
                    chooseSource(thenRecord: true)
                    return
                }
                guard ensureMicrophoneAccess() else { return }
                let device = InputDeviceRecorder(fileURL: url, deviceID: deviceID, channels: input.channels)
                try device.start()
                recorder = device
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            presentError(error, message: "録音を開始できませんでした")
            return
        }

        self.recorder = recorder
        recordingURL = url
        recordingDate = Date()
        sampleRate = recorder.format?.sampleRate ?? 48_000
        peaks = []
        livePeak = 0
        elapsed = 0
        overviewCache = nil
        if let meter = recorder.meter { peaksPerSecond = sampleRate / Double(meter.framesPerPeak) }
        didSave = false
        wasDelivered = false
        dragExport = nil

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullMeter() }
        }
        transition(to: .recording)
    }

    /// True when recording may start now; otherwise asks for access (and
    /// starts once granted) or explains how to allow it.
    private func ensureMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.startRecording() }
                }
            }
            return false
        default:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "マイクへのアクセスが許可されていません"
            alert.informativeText = "システム設定 › プライバシーとセキュリティ › マイク で Wasabi Recorder を許可してください。"
            alert.addButton(withTitle: "システム設定を開く")
            alert.addButton(withTitle: "キャンセル")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    private func pullMeter() {
        guard let meter = recorder?.meter else { return }
        let (newPeaks, frames) = meter.drain()
        if !newPeaks.isEmpty {
            peaks.append(contentsOf: newPeaks)
            livePeak = max(livePeak, newPeaks.max() ?? 0)
        }
        elapsed = Double(frames) / sampleRate
    }

    private func stopRecording() {
        guard let recorder else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        recorder.stop()
        pullMeter()
        self.recorder = nil

        duration = elapsed
        guard duration >= Self.minimumSelection, let url = recordingURL else {
            discardRecordingFile()
            transition(to: .idle)
            return
        }
        selection = 0...duration
        playhead = nil
        discardArmed = false
        player = try? PreviewPlayer(url: url)
        isAutoGain = true
        updateAutoGain()
        transition(to: .editing)
    }

    // MARK: - Waveform

    /// Peak envelope reduced to `bars` columns; cached because the editor
    /// redraws at display rate during playback.
    func overview(bars: Int) -> [Float] {
        if let overviewCache, overviewCache.bars == bars { return overviewCache.values }
        guard bars > 0, !peaks.isEmpty else { return [] }
        var values = [Float](repeating: 0, count: bars)
        let count = peaks.count
        for bar in 0..<bars {
            let lower = bar * count / bars
            let upper = max(lower + 1, (bar + 1) * count / bars)
            values[bar] = peaks[lower..<min(upper, count)].max() ?? 0
        }
        overviewCache = (bars, values)
        return values
    }

    // MARK: - Trimming

    func setSelectionStart(_ time: TimeInterval) {
        let start = min(max(0, time), selection.upperBound - Self.minimumSelection)
        selection = start...selection.upperBound
        updateAutoGain()
    }

    func setSelectionEnd(_ time: TimeInterval) {
        let end = max(min(duration, time), selection.lowerBound + Self.minimumSelection)
        selection = selection.lowerBound...end
        updateAutoGain()
    }

    func setSelection(from a: TimeInterval, to b: TimeInterval) {
        var lower = max(0, min(a, b))
        var upper = min(duration, max(a, b))
        if upper - lower < Self.minimumSelection {
            upper = min(duration, lower + Self.minimumSelection)
            lower = max(0, upper - Self.minimumSelection)
        }
        selection = lower...upper
        updateAutoGain()
    }

    func resetSelection() {
        selection = 0...duration
        updateAutoGain()
    }

    // MARK: - Gain

    func setGain(_ db: Double) {
        isAutoGain = false
        applyGain((db * 2).rounded() / 2)
    }

    func nudgeGain(by delta: Double) {
        setGain(gainDB + delta)
    }

    func enableAutoGain() {
        isAutoGain = true
        updateAutoGain()
    }

    private func updateAutoGain() {
        guard isAutoGain, !peaks.isEmpty else { return }
        let lower = min(peaks.count - 1, max(0, Int(selection.lowerBound * peaksPerSecond)))
        let upper = min(peaks.count, max(lower + 1, Int((selection.upperBound * peaksPerSecond).rounded(.up))))
        let peak = peaks[lower..<upper].max() ?? 0
        let db = peak > 0.00001 ? Double(20 * log10(Self.autoGainTarget / peak)) : 0
        applyGain((db * 10).rounded(.down) / 10)
    }

    private func applyGain(_ db: Double) {
        gainDB = db.clamped(to: Self.gainRange)
        player?.gainDB = gainDB
    }

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? pausePlayback() : startPlayback()
    }

    func seek(to time: TimeInterval) {
        let time = min(max(0, time), duration)
        playhead = time
        if isPlaying { play(from: time) }
    }

    private func startPlayback() {
        var start = playhead ?? selection.lowerBound
        if start < selection.lowerBound || selection.upperBound - start < 0.02 {
            start = selection.lowerBound
        }
        guard play(from: start) else { return }
        isPlaying = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPlayback() }
        }
    }

    @discardableResult
    private func play(from start: TimeInterval) -> Bool {
        guard let player, start < selection.upperBound else { return false }
        do {
            try player.play(from: start, to: selection.upperBound)
        } catch {
            return false
        }
        playhead = start
        return true
    }

    private func tickPlayback() {
        guard let time = player?.currentTime, time < selection.upperBound else {
            pausePlayback()
            playhead = nil
            return
        }
        playhead = time
    }

    private func pausePlayback() {
        player?.stop()
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
    }

    // MARK: - Discard & save

    func discardTapped() {
        guard phase == .editing, !isSaving else { return }
        discardReset?.cancel()
        if discardArmed || wasDelivered {
            discardArmed = false
            finishSession()
            return
        }
        withAnimation(.snappy) { discardArmed = true }
        discardReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.discardArmed = false }
        }
    }

    func save() {
        guard phase == .editing, !isSaving, !didSave, let source = recordingURL else { return }
        pausePlayback()

        let format = exportFormat
        let panel = NSSavePanel()
        let accessory = FormatAccessory(format: format, panel: panel)
        panel.accessoryView = accessory.view
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(defaultFileName).\(format.rawValue)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let destination = panel.url else { return }
                UserDefaults.standard.set(accessory.format.rawValue, forKey: Self.exportFormatKey)
                self.export(source, to: destination, format: accessory.format)
            }
        }
    }

    // MARK: - Drag out

    private var exportFormat: ExportFormat {
        ExportFormat(rawValue: UserDefaults.standard.string(forKey: Self.exportFormatKey) ?? "") ?? .wav
    }

    /// Renders the current trim and gain into ~/Music/Wasabi Recorder for a
    /// drag session. Reuses the last file when nothing changed.
    func fileForDrag() -> URL? {
        guard phase == .editing, let source = recordingURL else { return nil }
        let range = selection, gain = gainLinear, format = exportFormat
        if let dragExport, dragExport.range == range, dragExport.gain == gain, dragExport.format == format,
           FileManager.default.fileExists(atPath: dragExport.url.path) {
            return dragExport.url
        }
        do {
            try FileManager.default.createDirectory(at: Self.dragDirectory, withIntermediateDirectories: true)
            let url = uniqueURL(in: Self.dragDirectory, name: defaultFileName, extension: format.rawValue)
            try Exporter.export(from: source, range: range, gain: gain, to: url, format: format)
            dragExport = DragExport(range: range, gain: gain, format: format, url: url)
            return url
        } catch {
            presentError(error, message: "書き出せませんでした")
            return nil
        }
    }

    func dragEnded(delivered: Bool) {
        guard delivered else { return }
        wasDelivered = true
        dropConfirmReset?.cancel()
        withAnimation(.snappy) { dropConfirmed = true }
        dropConfirmReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.dropConfirmed = false }
        }
    }

    private func uniqueURL(in directory: URL, name: String, extension ext: String) -> URL {
        var url = directory.appending(path: "\(name).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(name) \(index).\(ext)")
            index += 1
        }
        return url
    }

    private var defaultFileName: String {
        let date = recordingDate.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
            timeZone: .current,
            calendar: .current
        ))
        let name = (source?.name ?? "Recording").replacingOccurrences(of: "/", with: "-")
        return "\(name) \(date)"
    }

    private func export(_ source: URL, to destination: URL, format: ExportFormat) {
        isSaving = true
        let range = selection
        let gain = gainLinear
        Task.detached(priority: .userInitiated) {
            let result = Result { try Exporter.export(from: source, range: range, gain: gain, to: destination, format: format) }
            await MainActor.run { self.exportFinished(result) }
        }
    }

    private func exportFinished(_ result: Result<Void, Error>) {
        isSaving = false
        switch result {
        case .success:
            withAnimation(.snappy) { didSave = true }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                self?.finishSession()
            }
        case .failure(let error):
            presentError(error, message: "保存できませんでした")
        }
    }

    private func finishSession() {
        pausePlayback()
        player = nil
        playhead = nil
        discardRecordingFile()
        transition(to: .idle)
    }

    private func discardRecordingFile() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    func tearDown() {
        meterTimer?.invalidate()
        recorder?.stop()
        recorder = nil
        pausePlayback()
        try? FileManager.default.removeItem(at: Self.temporaryDirectory)
    }

    #if DEBUG
    /// Fake session for UI work: `WASABI_DEMO=1 swift run`.
    func runDemo() {
        source = AudioApps.current().first.map { .app($0.identity) }
        peaks = []
        elapsed = 0
        transition(to: .recording)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                for _ in 0..<3 {
                    let t = Double(self.peaks.count) / 100
                    self.peaks.append(Float(abs(sin(t * 2.1)) * 0.06 + Double.random(in: 0...0.035)))
                }
                self.livePeak = self.peaks.max() ?? 0
                self.elapsed = Double(self.peaks.count) / 100
                guard self.elapsed > 4 else { return }
                timer.invalidate()
                self.duration = self.elapsed
                self.selection = 0.6...(self.duration - 0.8)
                self.playhead = 1.8
                self.isAutoGain = true
                self.updateAutoGain()
                self.transition(to: .editing)
            }
        }
    }
    #endif

    private func presentError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

/// Format switch shown in the save panel; keeps the file extension in sync.
@MainActor
final class FormatAccessory: NSObject {
    let view: NSView
    private(set) var format: ExportFormat
    private weak var panel: NSSavePanel?

    init(format: ExportFormat, panel: NSSavePanel) {
        self.format = format
        self.panel = panel
        let control = NSSegmentedControl(labels: ExportFormat.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = ExportFormat.allCases.firstIndex(of: format) ?? 0
        control.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        super.init()
        control.target = self
        control.action = #selector(changed(_:))
    }

    @objc private func changed(_ sender: NSSegmentedControl) {
        format = ExportFormat.allCases[sender.selectedSegment]
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.rawValue)"
    }
}
