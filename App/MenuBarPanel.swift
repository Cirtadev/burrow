import AppKit
import SwiftUI

/// A borderless panel hanging from the bottom of the menu bar, with an arrow pointing up at its status
/// item. (An NSPopover anchored to the status item overlaps the taller menu bar on notched Macs.)
@MainActor
final class MenuBarPanel: NSObject, NSWindowDelegate {
    static let arrowWidth: CGFloat = 22
    static let arrowHeight: CGFloat = 10
    static let cornerRadius: CGFloat = 12

    private let panel: KeyablePanel
    private let background = NSVisualEffectView()
    private let outline = OutlineView()
    private var hosting: NSHostingView<AnyView>!
    private var size = CGSize(width: 300, height: 400)
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private var closedAt = Date.distantPast

    var isShown: Bool { panel.isVisible }

    init(content: some View) {
        panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active

        let measured = content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] new in
                self?.resize(to: new)
            }
        hosting = NSHostingView(rootView: AnyView(measured))

        let container = NSView()
        for view in [background, hosting!, outline] as [NSView] { container.addSubview(view) }
        panel.contentView = container
        size = hosting.fittingSize
    }

    /// Opens under `button`, or closes if already open (a click on the icon toggles).
    func toggle(below button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else if Date.now.timeIntervalSince(closedAt) > 0.25 {
            // Clicking the icon first resigns the panel (closing it); don't reopen it on the same click.
            show(below: button)
        }
    }

    func show(below button: NSStatusBarButton) {
        anchor = button
        place()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = .now
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }

    private func resize(to new: CGSize) {
        guard new.width > 0, new.height > 0, new != size else { return }
        size = new
        if panel.isVisible { place() }
    }

    /// Arrow tip on the bottom edge of the menu bar under the icon; body centred on it, kept on screen.
    private func place() {
        guard let button = anchor, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        // The status item's window spans the menu bar, so its bottom is the menu bar's bottom
        // (also when the menu bar auto-hides and visibleFrame reaches the top of the screen).
        let menuBarBottom = min(visible.maxY, buttonWindow.frame.minY)

        let width = size.width
        let height = size.height + Self.arrowHeight
        let x = min(max(icon.midX - width / 2, visible.minX + 8), visible.maxX - width - 8).rounded()
        let y = (menuBarBottom - height - 1).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let inset = Self.cornerRadius + Self.arrowWidth / 2 + 2
        let arrowX = min(max(icon.midX - x, inset), width - inset)
        let shape = Self.shape(in: bounds, arrowX: arrowX)

        background.frame = bounds
        background.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
        outline.frame = bounds
        outline.shape = shape
        outline.needsDisplay = true
        panel.contentView?.needsDisplay = true
        panel.displayIfNeeded()
        panel.invalidateShadow()
    }

    /// Rounded rectangle with an arrow on its top edge, its tip at the top of `bounds`.
    static func shape(in bounds: NSRect, arrowX: CGFloat) -> NSBezierPath {
        let radius = cornerRadius
        let top = bounds.maxY - arrowHeight
        let half = arrowWidth / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX + radius, y: bounds.minY))
        path.appendArc(from: NSPoint(x: bounds.maxX, y: bounds.minY), to: NSPoint(x: bounds.maxX, y: top), radius: radius)
        path.appendArc(from: NSPoint(x: bounds.maxX, y: top), to: NSPoint(x: arrowX + half, y: top), radius: radius)
        path.line(to: NSPoint(x: arrowX + half, y: top))
        path.appendArc(from: NSPoint(x: arrowX, y: bounds.maxY), to: NSPoint(x: arrowX - half, y: top), radius: 3)
        path.line(to: NSPoint(x: arrowX - half, y: top))
        path.appendArc(from: NSPoint(x: bounds.minX, y: top), to: NSPoint(x: bounds.minX, y: bounds.minY), radius: radius)
        path.appendArc(from: NSPoint(x: bounds.minX, y: bounds.minY), to: NSPoint(x: bounds.maxX, y: bounds.minY), radius: radius)
        path.close()
        return path
    }
}

/// The thin edge around the panel and its arrow, like a menu's. Ignores clicks.
private final class OutlineView: NSView {
    var shape: NSBezierPath?

    override func draw(_ dirtyRect: NSRect) {
        guard let shape else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Borderless panels can't become key by default; this one can, so its buttons and Esc work.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
