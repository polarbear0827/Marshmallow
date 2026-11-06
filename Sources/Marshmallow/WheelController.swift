import AppKit
import SwiftUI

/// Transparent, non-activating panel that floats above everything.
final class WheelPanel: NSPanel {
    init() {
        let size = WheelGeometry.size
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true   // must come before `level`, it resets the level
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives drops, tracks hover, and lets the user drag results back out.
final class DropView: NSView, NSDraggingSource {
    weak var controller: WheelController?
    private var mouseDownPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Point relative to wheel center, y-down.
    private func rel(_ windowPoint: NSPoint) -> CGPoint {
        let p = convert(windowPoint, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: bounds.midY - p.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the circular area is interactive.
        let p = convert(point, from: superview)
        let d = hypot(p.x - bounds.midX, p.y - bounds.midY)
        return d <= WheelGeometry.outerRadius + 4 ? self : nil
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.setHover(nil) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let c = controller, c.isVisible, c.model.phase == .choosing, !c.isDraggingOut else { return [] }
        let idx = WheelGeometry.segment(at: rel(sender.draggingLocation), count: c.model.items.count)
        c.setHover(idx)
        // Only ever accept a *copy*. With ⌘ (move) or ⌃ (link) held the source offers
        // no copy, so we decline: the drag slides back and the original file can never
        // be moved. Our own mouse-up tracking still runs the chosen item. Because the
        // wheel is the topmost registered window, a declined drop doesn't fall through.
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if ProcessInfo.processInfo.environment["MM_DEBUG"] != nil { NSLog("MM performDragOperation") }
        guard let c = controller, c.isVisible else { return false }
        guard let idx = c.model.hovered else {
            // Dropped on the hole / rim: swallow it and cancel.
            DispatchQueue.main.async { c.hide() }
            return true
        }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? c.model.files
        c.perform(index: idx, files: urls)
        return true
    }

    // MARK: Drag results out / click

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, !c.model.results.isEmpty, let start = mouseDownPoint else { return }
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 { return }
        mouseDownPoint = nil
        let items: [NSDraggingItem] = c.model.results.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = c.model.thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - 40, y: p.y - 40, width: 80, height: 80), contents: img)
            return item
        }
        c.isDraggingOut = true
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller, mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        let r = rel(event.locationInWindow)
        if hypot(r.x, r.y) <= WheelGeometry.centerRadius, !c.model.results.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(c.model.results)
        }
        c.hide()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.isDraggingOut = false
        if operation != [] { controller?.hide() }
    }
}

/// Owns the panel and drives the wheel lifecycle.
final class WheelController {
    let model = WheelModel()
    private let panel = WheelPanel()
    private let dropView: DropView
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false
    var isDraggingOut = false
    private var isBusy = false
    /// Everything that draws. Hidden while the panel sits invisibly at the press point.
    private let visuals: NSView

    init() {
        let size = WheelGeometry.size
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        visuals = NSView(frame: container.bounds)
        visuals.isHidden = true
        container.addSubview(visuals)

        // On macOS 26+ the Liquid Glass comes from SwiftUI (`glassEffect`).
        // Older systems get a frosted, circle-masked blur disc underneath.
        if #unavailable(macOS 26) {
            let glassFrame = NSRect(x: WheelGeometry.padding, y: WheelGeometry.padding,
                                    width: WheelGeometry.outerRadius * 2, height: WheelGeometry.outerRadius * 2)
            let v = NSVisualEffectView(frame: glassFrame)
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.maskImage = NSImage(size: glassFrame.size, flipped: false) { r in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: r).fill()
                return true
            }
            visuals.addSubview(v)
        }

        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        visuals.addSubview(host)

        dropView = DropView(frame: container.bounds)
        container.addSubview(dropView)
        panel.contentView = container
        dropView.controller = self
    }

    // MARK: Lifecycle

    /// Panel origin that centers the wheel on `point`, kept on screen.
    private func frameOrigin(centeredAt point: NSPoint) -> NSPoint {
        let size = WheelGeometry.size
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX - WheelGeometry.padding), f.maxX - size + WheelGeometry.padding)
            origin.y = min(max(origin.y, f.minY - WheelGeometry.padding), f.maxY - size + WheelGeometry.padding)
        }
        return origin
    }

    /// Called on every left-button press. The drag system only routes a drag to
    /// windows that were already on screen when the drag began, so an invisible
    /// (fully transparent, click-through) panel is put in place at the press point.
    /// If a drag follows, the wheel is revealed right there and catches the drop,
    /// which also keeps the drop from landing on a window underneath.
    func prepare(at point: NSPoint) {
        guard !isVisible, !isBusy else { return }
        visuals.isHidden = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1
        panel.setFrameOrigin(frameOrigin(centeredAt: point))
        panel.orderFrontRegardless()
    }

    func show(files: [URL], mode: WheelMode, at point: NSPoint) {
        let items = Catalog.items(mode: mode, files: files)
        if items.isEmpty { return }
        if isVisible, model.phase == .choosing {
            if model.mode != mode { switchMode(mode, items: items) }
            return
        }
        if isVisible && isBusy { return }
        cancelHide()
        model.mode = mode
        model.items = items
        model.files = files
        model.hovered = nil
        model.results = []
        model.phase = .choosing
        if let f = files.first { model.loadThumbnail(for: f) }

        let origin = frameOrigin(centeredAt: point)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        // Fade at the window level; SwiftUI view animations stall while another
        // app owns the drag session and leave ghost frames behind.
        panel.alphaValue = 0
        visuals.isHidden = false
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func switchMode(_ mode: WheelMode, items: [WheelItem]) {
        model.mode = mode
        model.items = items
        model.hovered = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func setHover(_ idx: Int?) {
        guard model.hovered != idx else { return }
        model.hovered = idx
        if idx != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// Hover tracking driven by the global pointer position.
    ///
    /// macOS only routes an in-flight drag to windows that were already on screen
    /// when the drag began, so a wheel that pops up mid-drag never receives
    /// NSDraggingDestination callbacks. We therefore track the pointer ourselves.
    func trackPointer(_ screenPoint: NSPoint) {
        guard isVisible, model.phase == .choosing, !isBusy else { return }
        setHover(WheelGeometry.segment(at: relativePoint(screenPoint), count: model.items.count))
    }

    /// Screen point -> point relative to the wheel center, y-down.
    func relativePoint(_ p: NSPoint) -> CGPoint {
        let f = panel.frame
        return CGPoint(x: p.x - f.midX, y: f.midY - p.y)
    }

    /// Called when the mouse button is released after a file drag.
    func dragEnded(at screenPoint: NSPoint) {
        guard isVisible, model.phase == .choosing, !isBusy else { return }
        let idx = WheelGeometry.segment(at: relativePoint(screenPoint), count: model.items.count) ?? model.hovered
        // Released on the center hole (or outside): cancel.
        if let idx, hypot(relativePoint(screenPoint).x, relativePoint(screenPoint).y) >= WheelGeometry.ringInner - 4 {
            perform(index: idx, files: model.files)
        } else {
            hide()
        }
    }

    func hide() {
        guard isVisible, !isBusy else { return }
        cancelHide()
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            // Stay ordered in, but fully transparent and click-through.
            self.visuals.isHidden = true
            self.panel.ignoresMouseEvents = true
            self.panel.alphaValue = 1
            self.model.phase = .choosing
            self.model.results = []
        })
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func scheduleHide(after seconds: Double) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Keep it open while the pointer rests on it.
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame.insetBy(dx: WheelGeometry.padding, dy: WheelGeometry.padding), false) || self.isDraggingOut {
                self.scheduleHide(after: 1.5)
            } else {
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func handleClick(at point: NSPoint) {
        guard isVisible, !isBusy, model.phase != .choosing else { return }
        if !NSMouseInRect(point, panel.frame, false) { hide() }
    }

    // MARK: Running items

    func perform(index: Int, files: [URL]) {
        // Either the real drop or our own mouse-up tracking may arrive first; run once.
        guard model.phase == .choosing, !isBusy, model.items.indices.contains(index) else { return }
        let item = model.items[index]
        isBusy = true
        cancelHide()
        model.phase = .working(item.title)
        let mode = model.mode
        Task.detached(priority: .userInitiated) {
            let result: Result<ItemResult, Error>
            do { result = .success(try await item.run(files)) } catch { result = .failure(error) }
            await MainActor.run { self.finish(result, mode: mode, item: item) }
        }
    }

    @MainActor
    private func finish(_ result: Result<ItemResult, Error>, mode: WheelMode, item: WheelItem) {
        isBusy = false
        let settings = Settings.shared
        var ok = true
        if case .failure = result { ok = false }
        // Lets the onboarding practice pages know what the user just did.
        NotificationCenter.default.post(name: .wheelItemFinished, object: nil, userInfo: [
            "mode": mode.rawValue, "title": item.title, "success": ok,
        ])
        switch result {
        case .success(.files(let urls)):
            model.results = urls
            if let first = urls.first {
                model.loadThumbnail(for: first)
                let title = urls.count > 1 ? "\(urls.count) 個檔案" : first.lastPathComponent
                model.phase = .done(title: title, detail: urls.count > 1 ? "完成" : first.fileSizeString)
                if settings.revealAfter { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            } else {
                model.phase = .done(title: "完成", detail: "")
            }
            if settings.playSound { NSSound(named: "Pop")?.play() }
            scheduleHide(after: settings.hideDelay)
        case .success(.message(let msg)):
            model.phase = .done(title: msg, detail: "")
            if settings.playSound { NSSound(named: "Pop")?.play() }
            scheduleHide(after: min(settings.hideDelay, 2))
        case .failure(let error):
            model.phase = .failed(error.localizedDescription)
            NSSound(named: "Basso")?.play()
            scheduleHide(after: max(settings.hideDelay, 5))
        }
    }
}

extension Notification.Name {
    /// Posted after a wheel item runs. userInfo: mode (String), title (String), success (Bool).
    static let wheelItemFinished = Notification.Name("MarshmallowWheelItemFinished")
}
