import AppKit
import SwiftUI
import QuickLookThumbnailing

/// A small always-on-top card that holds files so they can be dragged out later.
final class FloatingShelf: NSObject, NSWindowDelegate {
    private static var open: [FloatingShelf] = []

    static func show(_ urls: [URL]) {
        let shelf = FloatingShelf(urls: urls)
        open.append(shelf)
        shelf.panel.orderFrontRegardless()
    }

    let urls: [URL]
    let panel: NSPanel

    init(urls: [URL]) {
        self.urls = urls
        let size = NSSize(width: 150, height: 172)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // drag the top bar to move it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let host = NSHostingView(rootView: ShelfView(urls: urls, close: { [weak self] in self?.close() }))
        host.frame = NSRect(origin: .zero, size: size)
        let drag = ShelfDragView(urls: urls, frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 28))
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        container.addSubview(drag)
        panel.contentView = container

        // Cascade near the pointer.
        let p = NSEvent.mouseLocation
        let offset = CGFloat(FloatingShelf.open.count % 6) * 18
        panel.setFrameOrigin(NSPoint(x: p.x + 40 + offset, y: p.y - size.height / 2 - offset))
    }

    func close() {
        panel.orderOut(nil)
        FloatingShelf.open.removeAll { $0 === self }
    }
}

private struct ShelfView: View {
    let urls: [URL]
    let close: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if urls.count > 1 {
                    Text("\(urls.count)").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(WheelView.accent))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 18)
            ZStack {
                if urls.count > 1 {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.4))
                        .frame(width: 92, height: 92).rotationEffect(.degrees(6))
                }
                Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 3, y: 1)
            }
            .frame(height: 104)
            Text(urls.count > 1 ? "\(urls.count) 個檔案" : urls[0].lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .frame(width: 150, height: 172)
        .modifier(ShelfBackground())
        .onAppear {
            let req = QLThumbnailGenerator.Request(fileAt: urls[0], size: CGSize(width: 192, height: 192), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                if let img = rep?.nsImage { DispatchQueue.main.async { thumb = img } }
            }
        }
    }
}

private struct ShelfBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        }
    }
}

/// Drag the files out of the shelf; dragging the window itself works from the top bar.
private final class ShelfDragView: NSView, NSDraggingSource {
    let urls: [URL]
    private var down: NSPoint?

    init(urls: [URL], frame: NSRect) {
        self.urls = urls
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { down = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        down = nil
        let p = convert(event.locationInWindow, from: nil)
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: p.x - 32 + CGFloat(i) * 4, y: p.y - 32 - CGFloat(i) * 4, width: 64, height: 64),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        down = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }
}
