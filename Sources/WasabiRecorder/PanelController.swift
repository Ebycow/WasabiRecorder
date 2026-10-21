import AppKit
import SwiftUI

enum PresentationMode: String {
    /// A free-floating panel the user can place anywhere.
    case window
    /// Lives in the menu bar; the panel drops down from the status item.
    case menuBar
}

final class GlassWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the borderless glass window. In window mode the panel grows from
/// whichever corner is closest to the screen edge; in menu bar mode it hangs
/// below the status item and hides when the user clicks elsewhere.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, PanelHost {
    private enum HorizontalAnchor { case leading, center, trailing }

    let window = GlassWindow()
    private let model: RecorderModel
    private(set) var mode: PresentationMode = .window

    private var anchorPoint = CGPoint.zero
    private var horizontal = HorizontalAnchor.leading
    private var growsDown = true
    private var isTransitioning = false
    private var outsideClickMonitor: Any?

    private static let originKey = "panelOrigin"

    init(model: RecorderModel) {
        self.model = model
        super.init()

        let hosting = NSHostingView(rootView: RootView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = self
        model.host = self
    }

    var isVisible: Bool { window.isVisible }

    // MARK: Modes

    func enterWindowMode() {
        mode = .window
        stopWatchingOutsideClicks()
        window.level = .floating
        window.isMovable = true
        placeAtSavedOrigin()
        show()
    }

    func enterMenuBarMode() {
        mode = .menuBar
        window.level = .statusBar
        window.isMovable = false
        hide()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() {
        stopWatchingOutsideClicks()
        window.orderOut(nil)
    }

    /// Menu bar mode: drop the panel down from `button`, or hide it if shown.
    func toggle(below button: NSStatusBarButton) {
        if window.isVisible {
            hide()
            return
        }
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let idleHalf = PanelLayout.size(for: .idle).width / 2
        let widestHalf = PanelLayout.size(for: .editing).width / 2
        let x = buttonRect.midX

        if x + widestHalf > visible.maxX - 8 {
            horizontal = .trailing
            anchorPoint.x = min(x + idleHalf, visible.maxX - 8)
        } else if x - widestHalf < visible.minX + 8 {
            horizontal = .leading
            anchorPoint.x = max(x - idleHalf, visible.minX + 8)
        } else {
            horizontal = .center
            anchorPoint.x = x
        }
        growsDown = true
        anchorPoint.y = buttonRect.minY - 6
        publishAlignment()
        apply(PanelLayout.size(for: model.phase))

        show()
        watchOutsideClicks()
    }

    private func watchOutsideClicks() {
        stopWatchingOutsideClicks()
        // Global monitors only see clicks in other apps, so our own menus,
        // popovers and save panels keep the panel open.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: PanelHost

    func beginTransition(covering size: CGSize) {
        if !isTransitioning, mode == .window { updateWindowAnchor() }
        isTransitioning = true
        let current = window.frame.size
        apply(CGSize(
            width: max(size.width, current.width - 2 * PanelLayout.margin),
            height: max(size.height, current.height - 2 * PanelLayout.margin)
        ))
    }

    func endTransition(at size: CGSize) {
        isTransitioning = false
        apply(size)
    }

    // MARK: Geometry

    private func updateWindowAnchor() {
        let panel = window.frame.insetBy(dx: PanelLayout.margin, dy: PanelLayout.margin)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? panel
        horizontal = panel.midX < screen.midX ? .leading : .trailing
        growsDown = panel.midY > screen.midY
        anchorPoint = CGPoint(
            x: horizontal == .leading ? panel.minX : panel.maxX,
            y: growsDown ? panel.maxY : panel.minY
        )
        publishAlignment()
    }

    private func publishAlignment() {
        let h: HorizontalAlignment = switch horizontal {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        model.anchor = Alignment(horizontal: h, vertical: growsDown ? .top : .bottom)
    }

    private func apply(_ panelSize: CGSize) {
        let m = PanelLayout.margin
        let x: CGFloat = switch horizontal {
        case .leading: anchorPoint.x - m
        case .center: anchorPoint.x - panelSize.width / 2 - m
        case .trailing: anchorPoint.x - panelSize.width - m
        }
        let frame = CGRect(
            x: x,
            y: growsDown ? anchorPoint.y + m - (panelSize.height + 2 * m) : anchorPoint.y - m,
            width: panelSize.width + 2 * m,
            height: panelSize.height + 2 * m
        )
        window.setFrame(frame, display: true)
    }

    private func placeAtSavedOrigin() {
        let size = PanelLayout.size(for: model.phase)
        let m = PanelLayout.margin
        let windowSize = CGSize(width: size.width + 2 * m, height: size.height + 2 * m)
        var origin: CGPoint?

        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let point = NSPointFromString(saved)
            let rect = CGRect(origin: point, size: windowSize).insetBy(dx: m, dy: m)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { origin = point }
        }
        if origin == nil, let screen = NSScreen.main?.visibleFrame {
            origin = CGPoint(x: screen.maxX - windowSize.width - 12, y: screen.maxY - windowSize.height - 12)
        }
        window.setFrame(CGRect(origin: origin ?? .zero, size: windowSize), display: false)
        updateWindowAnchor()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard mode == .window, !isTransitioning, model.phase == .idle else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originKey)
    }
}
