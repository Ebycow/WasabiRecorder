import AppKit

/// Native menu of recording sources: apps that own audio processes (those
/// currently producing sound first), then input devices with their channels.
@MainActor
enum SourcePicker {
    static func present(
        apps: [AudioApp],
        inputs: [InputDevice],
        selected: RecordingSource?,
        onPick: @escaping (RecordingSource) -> Void
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if apps.isEmpty {
            let item = NSMenuItem(title: "音声を使用中のアプリがありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        var previousWasPlaying: Bool?
        for app in apps {
            if let previousWasPlaying, previousWasPlaying != app.isPlaying {
                menu.addItem(.separator())
            }
            previousWasPlaying = app.isPlaying

            let item = ActionMenuItem(title: app.name) { onPick(.app(app.identity)) }
            item.image = resized(app.icon)
            if case .app(let current) = selected, app.matches(current) { item.state = .on }
            menu.addItem(item)
        }

        if !inputs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "マイク"))
        }
        for device in inputs {
            menu.addItem(inputItem(for: device, selected: selected, onPick: onPick))
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func inputItem(
        for device: InputDevice,
        selected: RecordingSource?,
        onPick: @escaping (RecordingSource) -> Void
    ) -> NSMenuItem {
        var current: InputSelection?
        if case .input(let input) = selected, device.matches(input) { current = input }

        func pick(_ channels: [Int]) {
            onPick(.input(InputSelection(deviceUID: device.uid, deviceName: device.name, channels: channels)))
        }

        let item: NSMenuItem
        if device.channelCount == 1 {
            item = ActionMenuItem(title: device.name) { pick([0]) }
        } else {
            // Interfaces often carry a mono mic on a single input, so let the
            // user pick exactly which channels end up in the file.
            item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(.sectionHeader(title: "モノラル"))
            for channel in 0..<device.channelCount {
                let choice = ActionMenuItem(title: "入力 \(channel + 1)") { pick([channel]) }
                if current?.channels == [channel] { choice.state = .on }
                submenu.addItem(choice)
            }
            submenu.addItem(.sectionHeader(title: "ステレオ"))
            for left in stride(from: 0, to: device.channelCount - 1, by: 2) {
                let choice = ActionMenuItem(title: "入力 \(left + 1)-\(left + 2)") { pick([left, left + 1]) }
                if current?.channels == [left, left + 1] { choice.state = .on }
                submenu.addItem(choice)
            }
            item.submenu = submenu
        }
        item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        if current != nil { item.state = .on }
        return item
    }

    private static func resized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
