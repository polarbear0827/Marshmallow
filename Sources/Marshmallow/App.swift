import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()

        monitor.onMouseDown = { [weak self] p in
            guard Settings.shared.enabled else { return }
            self?.wheel.prepare(at: p)
        }
        monitor.onDrag = { [weak self] files, mode, origin, location in
            guard let self, Settings.shared.enabled else { return }
            if self.wheel.isDraggingOut { self.monitor.ignoreCurrentDrag = true; return }
            if let mode { self.wheel.show(files: files, mode: mode, at: origin) }
            self.wheel.trackPointer(location)
        }
        monitor.onDragEnded = { [weak self] location in
            self?.wheel.dragEnded(at: location)
        }
        monitor.onClick = { [weak self] p in self?.wheel.handleClick(at: p) }
        monitor.start()

        // Tutorial on every launch until「不再顯示新手教學」is ticked.
        if Settings.shared.showOnboarding {
            Settings.shared.didOnboard = true
            OnboardingWindow.show()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icons.menuBar()
        statusItem.button?.toolTip = "Marshmallow"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Marshmallow \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "啟用拖曳輪盤", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = Settings.shared.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let s = Settings.shared
        for (mode, combo) in [(WheelMode.convert, s.convertCombo), (.tools, s.toolsCombo), (.actions, s.actionsCombo)] {
            let item = NSMenuItem(title: "\(combo.label) → \(mode.title)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "新手教學…", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "GitHub 專案頁面", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 Marshmallow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        rebuildMenu()
    }

    @objc private func openOnboarding() { OnboardingWindow.show() }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/polarbear0827/Marshmallow")!)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Marshmallow 設定"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    // Rebuild after closing so labels reflect any settings changes.
    func menuDidClose(_ menu: NSMenu) { rebuildMenu() }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

// MARK: - Icons

enum Icons {
    /// A little marshmallow drawn as a template image.
    static func menuBar() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 3, y: 2.5, width: 12, height: 11), xRadius: 4, yRadius: 4)
            body.lineWidth = 1.6
            body.stroke()
            let top = NSBezierPath(ovalIn: NSRect(x: 3.8, y: 9.5, width: 10.4, height: 4.6))
            top.lineWidth = 1.4
            top.stroke()
            // A tiny toasted dot.
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 5, width: 2.8, height: 2.2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Entry point

@main
enum MarshmallowMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        // Headless mode for testing: Marshmallow --run <convert|tools|actions> <item-id> <files...>
        if args.count >= 4, args[1] == "--run" {
            HeadlessRunner.run(mode: args[2], itemID: args[3], files: args.dropFirst(4).map { URL(fileURLWithPath: $0) })
            app.setActivationPolicy(.prohibited)
            app.run()
            return
        }
        // Visual check: Marshmallow --demo <convert|tools|actions> <hoverIndex> <file>
        if args.count >= 5, args[1] == "--demo" {
            app.setActivationPolicy(.accessory)
            let wheel = WheelController()
            DispatchQueue.main.async {
                let f = NSScreen.screens[0].frame
                wheel.show(files: [URL(fileURLWithPath: args[4])], mode: WheelMode(rawValue: args[2]) ?? .convert,
                           at: NSPoint(x: f.midX, y: f.midY))
                if let i = Int(args[3]), i >= 0 { wheel.setHover(i) }
            }
            withExtendedLifetime(wheel) { app.run() }
            return
        }
        // Mouse-free self test: Marshmallow --selftest <dx> <dy> <file...>
        // Shows the wheel off-screen, feeds a synthetic pointer path, releases at center+(dx,dy).
        if args.count >= 5, args[1] == "--selftest" {
            setvbuf(stdout, nil, _IONBF, 0)
            print("start")
            app.setActivationPolicy(.prohibited)
            let wheel = WheelController()
            print("controller ready")
            let files = args.dropFirst(4).map { URL(fileURLWithPath: $0) }
            let dx = Double(args[2])!, dy = Double(args[3])!
            DispatchQueue.main.async {
                let c = NSPoint(x: -20000, y: -20000)   // no screen here, so it stays invisible
                wheel.show(files: files, mode: .convert, at: c)
                for i in 1...10 { wheel.trackPointer(NSPoint(x: c.x + dx * Double(i) / 10, y: c.y + dy * Double(i) / 10)) }
                let idx = wheel.model.hovered
                print("hovered:", idx.map { wheel.model.items[$0].id } ?? "none")
                wheel.dragEnded(at: NSPoint(x: c.x + dx, y: c.y + dy))
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                    switch wheel.model.phase {
                    case .done(let t, let d): print("DONE:", t, d); exit(0)
                    case .failed(let m): print("FAILED:", m); exit(1)
                    case .choosing: print("CANCELLED (wheel hidden:", !wheel.isVisible, ")"); exit(0)
                    case .working: print("working…")
                    }
                }
            }
            withExtendedLifetime(wheel) { app.run() }
            return
        }
        // Editor check: Marshmallow --editor-test <edit|annotate|crop|redact|addBackground> <file>
        // Opens off-screen (no focus change), prints the window number, saves the result.
        if args.count >= 4, args[1] == "--editor-test", let mode = EditorMode(rawValue: args[2]) {
            setvbuf(stdout, nil, _IONBF, 0)
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                do {
                    let (w, model) = try ImageEditorWindow.presentForTest(URL(fileURLWithPath: args[3]), mode: mode)
                    print("WINDOW \(w.windowNumber)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        do { print("SAVED \(try model.save().path)") } catch { print("ERROR \(error)") }
                        exit(0)
                    }
                } catch { print("ERROR \(error)"); exit(1) }
            }
            app.run()
            return
        }
        // Onboarding check: Marshmallow --onboarding-test <step>  (off-screen, prints window number)
        if args.count >= 3, args[1] == "--onboarding-test", let step = Int(args[2]) {
            setvbuf(stdout, nil, _IONBF, 0)
            app.setActivationPolicy(.accessory)
            let w = OnboardingWindow()
            w.model.step = step
            if args.count >= 4 { w.model.done[.convert] = "PDF" }
            w.window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            w.window.orderFrontRegardless()
            print("WINDOW \(w.window.windowNumber)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            withExtendedLifetime(w) { app.run() }
            return
        }
        if args.count >= 3, args[1] == "--list" {
            let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
            for mode in WheelMode.allCases {
                print(mode.rawValue + ": " + Catalog.items(mode: mode, files: files).map(\.id).joined(separator: " "))
            }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum HeadlessRunner {
    static func run(mode: String, itemID: String, files: [URL]) {
        guard let mode = WheelMode(rawValue: mode),
              let item = Catalog.items(mode: mode, files: files).first(where: { $0.id == itemID }) else {
            print("ERROR: no item \(itemID)"); exit(2)
        }
        Task.detached {
            do {
                switch try await item.run(files) {
                case .files(let urls): urls.forEach { print("OUT: \($0.path) [\($0.fileSizeString)]") }
                case .message(let m): print("MSG: \(m)")
                }
                exit(0)
            } catch {
                print("ERROR: \(error.localizedDescription)"); exit(1)
            }
        }
    }
}
