// PreviewSplit.swift — 1.2.1 §2: split between preview and grid whose divider position is remembered
import AppKit
import SwiftUI

/// Preview above, left or right of the grid with a draggable divider. The preview's share is kept per
/// position in `GridSettings` (VSplitView/HSplitView of 1.1 forgot it on every launch).
struct PreviewSplit<Preview: View, Grid: View>: View {
    let position: PreviewPosition
    let settings: GridSettings
    /// The large preview's zoom: beside the grid its width follows it (spec 1.3.2 Teil B); nil = fixed width.
    var zoom: PreviewZoom?
    @ViewBuilder let preview: Preview
    @ViewBuilder let grid: Grid
    @State private var dragStart: CGFloat?
    @State private var hovering = false
    /// The width shown while it follows the zoom (bundled and animated); nil = the target at once.
    @State private var shownWidth: CGFloat?
    @State private var bundler: WidthBundler?

    /// Room around the page in the preview: PDFView's margins and the scroller (spec 1.3.2 §9).
    static var pageMargin: CGFloat {
        24 + (NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0)
    }

    static var handleThickness: CGFloat { 7 }
    private var vertical: Bool { position == .top }
    private var minPreview: CGFloat { vertical ? 160 : 240 }
    private var minGrid: CGFloat { vertical ? 160 : 320 }

    var body: some View {
        GeometryReader { geo in
            let total = max((vertical ? geo.size.height : geo.size.width) - Self.handleThickness, 1)
            // B: the length the user set (spec 1.3.2 §9); beside the grid the shown width follows the zoom up to B.
            let reference = SplitMath.previewLength(fraction: settings.previewFraction(for: position), total: total,
                                                    minPreview: minPreview, minGrid: minGrid)
            let target = followsZoom ? targetWidth(reference: reference) : reference
            let length = dragStart != nil ? reference : min(shownWidth ?? target, reference)
            Group {
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
            .onAppear { publishReference(followsZoom ? reference : nil) }
            .onChange(of: followsZoom ? reference : -1) { _, _ in publishReference(followsZoom ? reference : nil) }
            // Only a width that follows the zoom is bundled; otherwise the length is B at once (a wider window).
            .onChange(of: target) { _, wanted in if followsZoom { follow(wanted) } else { shownWidth = nil } }
        }
    }

    /// Beside the grid with „Vorschaubreite an Zoom anpassen“ on.
    private var followsZoom: Bool { zoom != nil && !vertical && settings.previewFollowsZoom }

    /// The page's width at the shown zoom plus margin, at least the preview's minimum, at most B.
    private func targetWidth(reference: CGFloat) -> CGFloat {
        guard let zoom else { return reference }
        return PreviewWidthMath.paneWidth(page: zoom.pageSize, scale: CGFloat(zoom.currentPercent) / 100, margin: Self.pageMargin,
                                          minimum: minPreview, reference: reference)
    }

    /// B for the preview (levels and „Ganze Seite“ are measured against it, not against the width shown).
    private func publishReference(_ reference: CGFloat?) {
        guard let zoom else { return }
        // B is the view's width at the user's length; `PDFPageView.fillWidth` takes the scroller off.
        if zoom.referenceWidth != reference { zoom.referenceWidth = reference }
        if reference == nil { shownWidth = nil }
    }

    /// A new width: after a quick series of zoom steps only the last, animated (spec 1.3.2 §10).
    private func follow(_ wanted: CGFloat) {
        if shownWidth == nil { shownWidth = wanted; return }
        let bundler = self.bundler ?? WidthBundler { width in
            withAnimation(.easeOut(duration: 0.15)) { shownWidth = width }
        }
        if self.bundler == nil { self.bundler = bundler }
        bundler.request(wanted)
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
            .onEnded { _ in dragStart = nil; shownWidth = nil })      // the dragged length is the new B
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
    /// Without a stored frame: this content size for the visible screen size, and the window is centred (1.2.4).
    var defaultContentSize: (@MainActor (CGSize) -> CGSize)?
    /// false: only the user's own resizes (live resize) and moves are kept, not a size SwiftUI sets, e.g.
    /// when the settings tab changes (review I3).
    var savesProgrammaticResizes = true
    /// SwiftUI's settings window comes without `.resizable` although its content can grow (1.2.4 promised a
    /// window that can be enlarged; the UI test measured the main window instead).
    var makesResizable = false

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
        let defaultContentSize = self.defaultContentSize, savesProgrammaticResizes = self.savesProgrammaticResizes
        let makesResizable = self.makesResizable
        view.onWindow = { window in
            guard coordinator.window !== window else { return }
            coordinator.window = window
            coordinator.removeObservers()
            // After SwiftUI has placed the window (it restores its own frame first).
            DispatchQueue.main.async {
                if makesResizable { window.styleMask.insert(.resizable) }
                if load() == nil, let defaultContentSize {
                    let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
                    window.setContentSize(defaultContentSize(screen))
                    window.center()
                }
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
                         NSWindow.willCloseNotification] where savesProgrammaticResizes || name != NSWindow.didResizeNotification {
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
