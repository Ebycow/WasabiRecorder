import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = RecorderModel()
    private var panel: PanelController!
    private var statusItem: StatusItemController?

    static let modeKey = "presentationMode"

    static var storedMode: PresentationMode {
        PresentationMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        model.contextMenu = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        setMode(Self.storedMode, announce: false)
        #if DEBUG
        if ProcessInfo.processInfo.environment["WASABI_DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.panel.mode == .menuBar, let button = self.statusItem?.button { self.panel.toggle(below: button) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runDemo() }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel.mode == .window { panel.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "保存されていない録音があります"
        alert.informativeText = "終了すると録音は破棄されます。"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.tearDown()
    }

    // MARK: Presentation mode

    private func setMode(_ mode: PresentationMode, announce: Bool = true) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        switch mode {
        case .window:
            statusItem?.remove()
            statusItem = nil
            NSApp.setActivationPolicy(.regular)
            panel.enterWindowMode()
        case .menuBar:
            let status = statusItem ?? StatusItemController(
                model: model,
                onClick: { [weak self] button in self?.panel.toggle(below: button) },
                menu: { [weak self] in self?.makeContextMenu() ?? NSMenu() }
            )
            statusItem = status
            NSApp.setActivationPolicy(.accessory)
            panel.enterMenuBarMode()
            // Drop the panel once so it is obvious where it went.
            if announce {
                // Wait for the new status item to be laid out in the menu bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    if let button = status.button { self?.panel.toggle(below: button) }
                }
            }
        }
        NSApp.mainMenu = makeMainMenu()
    }

    private func makeModeItem() -> NSMenuItem {
        let item = ActionMenuItem(title: "メニューバーに常駐") { [weak self] in
            guard let self else { return }
            self.setMode(self.panel.mode == .menuBar ? .window : .menuBar)
        }
        item.state = panel.mode == .menuBar ? .on : .off
        return item
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeModeItem())
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Wasabi Recorder を終了") { NSApp.terminate(nil) })
        return menu
    }

    private func makeMainMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "\(name) について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(makeModeItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "\(name) を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "ほかを隠す", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "すべてを表示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "\(name) を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}

/// Menu bar icon. Left click drops the panel down, right click shows the
/// menu; while recording it turns into a red dot with the elapsed time.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: RecorderModel
    private let onClick: (NSStatusBarButton) -> Void
    private let menu: () -> NSMenu
    private var shownTitle: String?
    private var isRemoved = false

    var button: NSStatusBarButton? { item.button }

    init(model: RecorderModel, onClick: @escaping (NSStatusBarButton) -> Void, menu: @escaping () -> NSMenu) {
        self.model = model
        self.onClick = onClick
        self.menu = menu
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        observe()
    }

    func remove() {
        isRemoved = true
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            onClick(sender)
        }
    }

    private func observe() {
        guard !isRemoved else { return }
        withObservationTracking {
            update(recording: model.phase == .recording, elapsed: model.elapsed)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update(recording: Bool, elapsed: TimeInterval) {
        let title = recording ? TimeText.clock(elapsed) : ""
        guard title != shownTitle, let button = item.button else { return }
        let wasRecording = !(shownTitle ?? "").isEmpty
        shownTitle = title

        button.attributedTitle = NSAttributedString(string: recording ? " \(title)" : "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        ])
        guard recording != wasRecording || button.image == nil else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "録音中")?
                .withSymbolConfiguration(config)
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wasabi Recorder")
            image?.isTemplate = true
            button.image = image
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppDelegate.storedMode == .menuBar ? .accessory : .regular)
    app.run()
}
