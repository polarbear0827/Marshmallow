import AppKit

/// Detects system-wide file drags without needing Accessibility permission.
///
/// It polls the mouse button state; when the drag pasteboard changes while the
/// button is down, a drag session has started. Modifier keys are read from
/// `NSEvent.modifierFlags`, which works globally.
final class DragMonitor {
    /// `origin` is where the mouse went down (the wheel is centered there, like Tangerine).
    var onDrag: ((_ files: [URL], _ mode: WheelMode?, _ origin: NSPoint, _ location: NSPoint) -> Void)?
    /// Fired as soon as the left button goes down, before any drag starts.
    var onMouseDown: ((NSPoint) -> Void)?
    var onDragEnded: ((_ location: NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?

    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var wasDown = false
    private var startCount = 0
    private var files: [URL]?
    private var origin = NSPoint.zero
    private var clickMonitor: Any?
    /// Set while Marshmallow itself is the drag source.
    var ignoreCurrentDrag = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0          // no timer coalescing; drags need prompt updates
        RunLoop.main.add(t, forMode: .common)
        timer = t
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.onClick?(NSEvent.mouseLocation)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        if down && !wasDown {
            wasDown = true
            startCount = dragPasteboard.changeCount
            files = nil
            origin = NSEvent.mouseLocation
            onMouseDown?(origin)
            return
        }
        if !down && wasDown {
            wasDown = false
            if let files, !files.isEmpty, !ignoreCurrentDrag { onDragEnded?(NSEvent.mouseLocation) }
            files = nil
            ignoreCurrentDrag = false
            return
        }
        guard down else { return }

        if files == nil, dragPasteboard.changeCount != startCount {
            let urls = dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            // Only regular files (not folders) for now.
            let regular = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            files = regular
        }
        guard let files, !files.isEmpty, !ignoreCurrentDrag else { return }
        let mode = Settings.shared.mode(for: NSEvent.modifierFlags)
        onDrag?(files, mode, origin, NSEvent.mouseLocation)
    }
}
