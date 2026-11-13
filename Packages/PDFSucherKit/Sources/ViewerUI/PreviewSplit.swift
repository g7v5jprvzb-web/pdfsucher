// PreviewSplit.swift — 1.2.1 §2: split between preview and grid whose divider position is remembered
import AppKit
import SwiftUI

/// Preview above, left or right of the grid with a draggable divider. The preview's share is kept per
/// position in `GridSettings` (VSplitView/HSplitView of 1.1 forgot it on every launch).
struct PreviewSplit<Preview: View, Grid: View>: View {
    let position: PreviewPosition
    let settings: GridSettings
    @ViewBuilder let preview: Preview
    @ViewBuilder let grid: Grid
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    static var handleThickness: CGFloat { 7 }
    private var vertical: Bool { position == .top }
    private var minPreview: CGFloat { vertical ? 160 : 240 }
    private var minGrid: CGFloat { vertical ? 160 : 320 }

    var body: some View {
        GeometryReader { geo in
            let total = max((vertical ? geo.size.height : geo.size.width) - Self.handleThickness, 1)
            let length = SplitMath.previewLength(fraction: settings.previewFraction(for: position), total: total,
                                                 minPreview: minPreview, minGrid: minGrid)
            if vertical {
                VStack(spacing: 0) {
                    preview.frame(height: length)
                    handle(length: length, total: total)
                    grid.frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    if position == .trailing { grid.frame(maxWidth: .infinity) }
                    if position == .trailing { handle(length: length, total: total) }
                    preview.frame(width: length)
                    if position == .leading { handle(length: length, total: total) }
                    if position == .leading { grid.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func handle(length: CGFloat, total: CGFloat) -> some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
        }
        .frame(width: vertical ? nil : Self.handleThickness, height: vertical ? Self.handleThickness : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            // Balanced push/pop, also when the handle goes away while hovered (review M2).
            guard inside != hovering else { return }
            hovering = inside
            if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? length
                if dragStart == nil { dragStart = length }
                let moved = vertical ? value.translation.height : value.translation.width
                // The preview grows towards the grid: down (top), right (leading), left (trailing).
                let wanted = start + (position == .trailing ? -moved : moved)
                let clamped = SplitMath.previewLength(fraction: SplitMath.fraction(previewLength: wanted, total: total),
                                                      total: total, minPreview: minPreview, minGrid: minGrid)
                settings.setPreviewFraction(SplitMath.fraction(previewLength: clamped, total: total), for: position)
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement()
        .accessibilityLabel("Trenner Vorschau / Raster")
        .accessibilityIdentifier("previewSplitter")
    }
}

/// Restores and saves the frame of the window it is placed in (1.2.1 §2). `size: false` keeps only the
/// top-left corner (the settings window takes its size from the chosen tab): `load` then returns a
/// zero-size rect whose origin is that corner.
struct WindowFrameKeeper: NSViewRepresentable {
    let load: @MainActor () -> CGRect?
    let save: @MainActor (CGRect) -> Void
    var size = true

    final class HostView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor final class Coordinator {
        var observers: [NSObjectProtocol] = []
        weak var window: NSWindow?
        var applied = false
        func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        let coordinator = context.coordinator
        let load = self.load, save = self.save, keepSize = self.size
        view.onWindow = { window in
            guard coordinator.window !== window else { return }
            coordinator.window = window
            coordinator.removeObservers()
            // After SwiftUI has placed the window (it restores its own frame first).
            DispatchQueue.main.async {
                if let stored = load() {
                    let wanted = keepSize ? stored
                        : CGRect(x: stored.minX, y: stored.minY - window.frame.height, width: window.frame.width, height: window.frame.height)
                    let screens = NSScreen.screens.map(\.visibleFrame)
                    window.setFrame(WindowPlacement.fitted(wanted, visibleFrames: screens, minSize: window.minSize), display: true)
                }
                coordinator.applied = true
            }
            let store: @MainActor () -> Void = { [weak window] in
                // Full screen is not a window size to come back to (review M4).
                guard coordinator.applied, let window, window.isVisible, !window.inLiveResize,
                      !window.styleMask.contains(.fullScreen) else { return }
                save(window.frame)
            }
            // Not every live-resize step (review M3): the end of a resize, a move, programmatic resizes, closing.
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification,
                         NSWindow.willCloseNotification] {
                coordinator.observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { store() }
                })
            }
        }
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {}

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.removeObservers()
    }
}
