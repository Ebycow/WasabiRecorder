import AppKit
import SwiftUI

extension Color {
    static let wasabi = Color(nsColor: NSColor(name: "wasabi") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.64, green: 0.87, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.62, blue: 0.15, alpha: 1)
    })

    static let clipping = Color(red: 1, green: 0.36, blue: 0.3)
}

enum TimeText {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func precise(_ seconds: TimeInterval) -> String {
        let tenths = Int((seconds * 10).rounded())
        let total = tenths / 10
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths % 10)
            : String(format: "%d:%02d.%d", m, s, tenths % 10)
    }
}

// MARK: - Root

struct RootView: View {
    let model: RecorderModel
    @Namespace private var namespace

    var body: some View {
        let size = PanelLayout.size(for: model.phase)
        let shape = RoundedRectangle(cornerRadius: PanelLayout.cornerRadius(for: model.phase), style: .continuous)

        ZStack {
            if model.phase == .editing {
                EditorPanel(model: model, namespace: namespace)
                    .transition(.blurReplace)
            } else {
                CaptureBar(model: model, namespace: namespace)
                    .transition(.blurReplace)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(WindowDragArea(menu: model.contextMenu))
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .padding(PanelLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor)
    }
}

// MARK: - Idle / recording

struct CaptureBar: View {
    let model: RecorderModel
    let namespace: Namespace.ID

    var body: some View {
        let recording = model.phase == .recording

        HStack(spacing: 8) {
            SourceButton(source: model.source) { model.chooseSource() }
                .allowsHitTesting(!recording)

            if recording {
                LiveWaveform(peaks: model.peaks, gain: model.liveDisplayGain)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .matchedGeometryEffect(id: "waveform", in: namespace)
                    .transition(.opacity.combined(with: .scale(scale: 0.3, anchor: .trailing)))

                Text(TimeText.clock(model.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }

            RecordButton(isRecording: recording) { model.recordButtonTapped() }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SourceButton: View {
    let source: RecordingSource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch source {
                case .app(let app):
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                case .input(let input):
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.wasabi)
                        .frame(width: 28, height: 28)
                        .overlay(alignment: .bottomTrailing) {
                            Text(input.channelLabel)
                                .font(.system(size: 8, weight: .bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(x: 4, y: 2)
                        }
                case nil:
                    Image(systemName: "app.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(HoverButtonStyle())
        .help(helpText)
        .accessibilityLabel(source?.name ?? "録音するアプリを選択")
    }

    private var helpText: String {
        switch source {
        case .app(let app): app.name
        case .input(let input): "\(input.deviceName) · 入力 \(input.channelLabel)（\(input.isMono ? "モノラル" : "ステレオ")）"
        case nil: ""
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
                RoundedRectangle(cornerRadius: isRecording ? 4.5 : 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 1, green: 0.38, blue: 0.33), Color(red: 0.88, green: 0.13, blue: 0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: isRecording ? 15 : 24, height: isRecording ? 15 : 24)
                    .shadow(color: .red.opacity(0.35), radius: 4, y: 1)
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(isRecording ? "停止" : "録音")
    }
}

// MARK: - Waveforms

enum Waveform {
    static let barWidth: CGFloat = 2
    static let barStep: CGFloat = 3.5

    static func barRect(x: CGFloat, level: Float, height: CGFloat) -> CGRect {
        let h = max(2, CGFloat(pow(level, 0.6)) * height)
        return CGRect(x: x, y: (height - h) / 2, width: barWidth, height: h)
    }
}

/// Scrolling tail of the recording; newest audio at the right edge.
struct LiveWaveform: View {
    let peaks: [Float]
    let gain: Float
    private let peaksPerBar = 5

    var body: some View {
        Canvas { context, size in
            let visibleBars = Int(size.width / Waveform.barStep)
            let bars = (peaks.count + peaksPerBar - 1) / peaksPerBar
            var path = Path()
            for i in 0..<min(visibleBars, bars) {
                let bar = bars - 1 - i
                let lower = bar * peaksPerBar
                let upper = min(lower + peaksPerBar, peaks.count)
                var level: Float = 0
                for j in lower..<upper { level = max(level, peaks[j]) }
                let x = size.width - CGFloat(i + 1) * Waveform.barStep
                path.addRoundedRect(in: Waveform.barRect(x: x, level: min(1, level * gain), height: size.height), cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(.wasabi))
        }
        .mask(LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
            startPoint: .leading,
            endPoint: .trailing
        ))
    }
}

// MARK: - Editor

struct EditorPanel: View {
    let model: RecorderModel
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: 8) {
            TrimWaveform(model: model)
                .frame(height: 66)
                .matchedGeometryEffect(id: "waveform", in: namespace)

            ZStack {
                HStack(spacing: 2) {
                    DiscardButton(armed: model.discardArmed) { model.discardTapped() }
                    IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }
                        .keyboardShortcut(.space, modifiers: [])
                        .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")
                    Spacer()
                    GainButton(model: model)
                    SaveButton(model: model)
                }

                Text(TimeText.precise(model.selection.upperBound - model.selection.lowerBound))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .padding(PanelLayout.editorPadding)
        .background {
            Group {
                Button("") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("") { model.save() }
                    .keyboardShortcut(.defaultAction)
                Button("") { model.nudgeGain(by: 1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { model.nudgeGain(by: -1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}

struct TrimWaveform: View {
    let model: RecorderModel
    private let dragAnchor = State<TimeInterval?>(initialValue: nil)

    private let handleHitWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(model.duration, 0.001)
            let x = { (time: TimeInterval) in CGFloat(time / duration) * width }
            let time = { (x: CGFloat) in TimeInterval(min(max(0, x), width) / width) * duration }
            let startX = x(model.selection.lowerBound)
            let endX = x(model.selection.upperBound)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.wasabi.opacity(0.12))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)

                WaveformBars(
                    values: model.overview(bars: Int(width / Waveform.barStep)),
                    selection: startX...endX,
                    gain: model.gainLinear
                )
                .animation(nil, value: model.gainLinear)
                .padding(.vertical, 6)

                if let playhead = model.playhead {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: x(playhead) - 1)
                        .allowsHitTesting(false)
                }

                TrimHandle()
                    .frame(width: handleHitWidth)
                    .offset(x: startX - handleHitWidth / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        model.setSelectionStart(time(value.location.x))
                    })

                TrimHandle()
                    .frame(width: handleHitWidth)
                    .offset(x: endX - handleHitWidth / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        model.setSelectionEnd(time(value.location.x))
                    })
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .coordinateSpace(.named("trim"))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let anchor = dragAnchor.wrappedValue ?? time(value.startLocation.x)
                dragAnchor.wrappedValue = anchor
                if abs(value.translation.width) > 3 {
                    model.setSelection(from: anchor, to: time(value.location.x))
                }
            }.onEnded { value in
                if abs(value.translation.width) <= 3 {
                    model.seek(to: time(value.startLocation.x))
                }
                dragAnchor.wrappedValue = nil
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.resetSelection() })
        }
    }
}

struct WaveformBars: View {
    let values: [Float]
    let selection: ClosedRange<CGFloat>
    let gain: Float

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            var inside = Path()
            var outside = Path()
            var clipped = Path()
            for (index, level) in values.enumerated() {
                let x = CGFloat(index) * step + (step - Waveform.barWidth) / 2
                let boosted = level * gain
                let rect = Waveform.barRect(x: x, level: min(1, boosted), height: size.height)
                let corner = CGSize(width: 1, height: 1)
                if !selection.contains(rect.midX) {
                    outside.addRoundedRect(in: rect, cornerSize: corner)
                } else if boosted > 1 {
                    clipped.addRoundedRect(in: rect, cornerSize: corner)
                } else {
                    inside.addRoundedRect(in: rect, cornerSize: corner)
                }
            }
            context.fill(outside, with: .color(.secondary.opacity(0.5)))
            context.fill(inside, with: .color(.wasabi))
            context.fill(clipped, with: .color(.clipping))
        }
        .allowsHitTesting(false)
    }
}

struct TrimHandle: View {
    private let hovering = State(initialValue: false)

    var body: some View {
        Capsule()
            .fill(Color.wasabi)
            .frame(width: hovering.wrappedValue ? 6 : 4)
            .overlay {
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 1.5, height: 12)
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.15), value: hovering.wrappedValue)
            .onHover { inside in
                hovering.wrappedValue = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Buttons

struct IconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(HoverButtonStyle())
    }
}

struct DiscardButton: View {
    let armed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: armed ? "trash.fill" : "xmark")
                .font(.system(size: armed ? 14 : 13, weight: .semibold))
                .foregroundStyle(armed ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.red.opacity(armed ? 0.9 : 0)))
        }
        .buttonStyle(HoverButtonStyle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("破棄")
    }
}

struct GainButton: View {
    let model: RecorderModel
    private let isPresented = State(initialValue: false)

    var body: some View {
        Button { isPresented.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(GainText.short(model.gainDB))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText(value: model.gainDB))
            }
            .foregroundStyle(model.isAutoGain ? AnyShapeStyle(Color.wasabi) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(isPresented.wrappedValue ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("音量")
        .accessibilityValue(GainText.long(model.gainDB))
        .popover(isPresented: isPresented.projectedValue, arrowEdge: .bottom) {
            GainPopover(model: model)
        }
    }
}

struct GainPopover: View {
    let model: RecorderModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.gainDB }, set: { model.setGain($0) }),
                    in: RecorderModel.gainRange
                )
                .tint(.wasabi)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(GainText.long(model.gainDB))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: model.gainDB))
                Spacer()
                Button { model.setGain(0) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("0 dB")
                Button { model.enableAutoGain() } label: {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(model.isAutoGain ? Color.wasabi : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("自動")
            }
        }
        .padding(14)
        .frame(width: 240)
        .animation(.snappy(duration: 0.2), value: model.gainDB)
    }
}

enum GainText {
    static func short(_ db: Double) -> String {
        abs(db) < 0.05 ? "0" : String(format: "%+.0f", db)
    }

    static func long(_ db: Double) -> String {
        abs(db) < 0.05 ? "0.0 dB" : String(format: "%+.1f dB", db)
    }
}

/// Click to save with a panel; drag to drop the trimmed, gain-adjusted file
/// straight into Finder, a DAW or a chat app. Right-click picks the format.
struct SaveButton: View {
    let model: RecorderModel
    private let isPressed = State(initialValue: false)

    var body: some View {
        let confirmed = model.didSave || model.dropConfirmed

        ZStack {
            if confirmed {
                Image(systemName: "checkmark")
                    .transition(.scale.combined(with: .opacity))
            } else if model.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "arrow.down")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 54, height: 32)
        .background(Capsule().fill(Color.wasabi.gradient))
        .shadow(color: Color.wasabi.opacity(0.35), radius: 6, y: 2)
        .scaleEffect(isPressed.wrappedValue ? 0.88 : 1)
        .brightness(isPressed.wrappedValue ? -0.06 : 0)
        .animation(.spring(duration: 0.25, bounce: 0.5), value: isPressed.wrappedValue)
        .overlay {
            FileDragSource(
                onPress: { isPressed.wrappedValue = $0 },
                onClick: { model.save() },
                prepareFile: { model.fileForDrag() },
                onDragEnd: { model.dragEnded(delivered: $0) },
                makeMenu: formatMenu
            )
        }
        .help("クリックで保存・ドラッグで \(model.exportFormat.label) を書き出し・右クリックで形式を選択")
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("保存")
        .accessibilityValue(model.exportFormat.label)
        .accessibilityAction { model.save() }
    }

    private func formatMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "書き出し形式"))
        for format in ExportFormat.allCases {
            let item = ActionMenuItem(title: format.label) { model.exportFormat = format }
            item.subtitle = format.summary
            item.state = format == model.exportFormat ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// AppKit mouse handling for the save button: a click runs `onClick`, a drag
/// starts a file drag session with the URL from `prepareFile`, a right-click
/// shows `makeMenu`.
struct FileDragSource: NSViewRepresentable {
    let onPress: (Bool) -> Void
    let onClick: () -> Void
    let prepareFile: () -> URL?
    let onDragEnd: (Bool) -> Void
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.onPress = onPress
        view.onClick = onClick
        view.prepareFile = prepareFile
        view.onDragEnd = onDragEnd
        view.makeMenu = makeMenu
    }

    final class SourceView: NSView, NSDraggingSource {
        var onPress: (Bool) -> Void = { _ in }
        var onClick: () -> Void = {}
        var prepareFile: () -> URL? = { nil }
        var onDragEnd: (Bool) -> Void = { _ in }
        var makeMenu: () -> NSMenu? = { nil }

        private var mouseDownLocation: NSPoint?
        private var isDragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = makeMenu() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
            mouseDownLocation = event.locationInWindow
            isDragging = false
            onPress(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let start = mouseDownLocation,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
            isDragging = true
            onPress(false)
            NSCursor.closedHand.set()
            guard let url = prepareFile() else { return }

            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            let point = convert(start, from: nil)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            onPress(false)
            if !isDragging, bounds.contains(convert(event.locationInWindow, from: nil)) {
                onClick()
            }
            mouseDownLocation = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            mouseDownLocation = nil
            onDragEnd(operation != [])
        }
    }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        private let hovering = State(initialValue: false)

        var body: some View {
            configuration.label
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering.wrappedValue ? 0.07 : 0)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.snappy(duration: 0.18), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering.wrappedValue)
                .onHover { hovering.wrappedValue = $0 }
        }
    }
}

struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.5), value: configuration.isPressed)
    }
}

// MARK: - Window dragging

/// Empty glass is a drag handle for the borderless window (when it is
/// movable) and opens the panel's context menu on right-click.
struct WindowDragArea: NSViewRepresentable {
    let menu: (() -> NSMenu)?

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.makeMenu = menu
    }

    final class DragView: NSView {
        var makeMenu: (() -> NSMenu)?

        override func mouseDown(with event: NSEvent) {
            guard window?.isMovable == true else { return }
            window?.performDrag(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu?()
        }
    }
}
