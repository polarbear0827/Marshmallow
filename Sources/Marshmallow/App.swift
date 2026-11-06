import AppKit
import Combine
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

    /// Ask before quitting while conversions are still running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = JobCenter.shared.jobs.count
        guard n > 0 else { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "還有 \(n) 個工作在處理中"
        alert.informativeText = "現在結束會取消這些工作，做到一半的檔案會被刪除。"
        alert.addButton(withTitle: "繼續處理")
        alert.addButton(withTitle: "取消並結束")
        if alert.runModal() == .alertSecondButtonReturn {
            JobCenter.shared.cancelAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Icons.menuBar()
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = "Marshmallow"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        JobCenter.shared.onChange = { [weak self] in self?.updateStatusTitle() }
        JobCenter.shared.setUpNotifications()
    }

    /// Shows overall progress next to the icon while jobs run.
    private func updateStatusTitle() {
        let center = JobCenter.shared
        guard let button = statusItem.button else { return }
        if center.jobs.isEmpty {
            button.title = ""
        } else {
            let pct = center.overallProgress.map { " \(Int($0 * 100))%" } ?? " …"
            let count = center.jobs.count > 1 ? " ×\(center.jobs.count)" : ""
            button.title = pct + count
        }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    /// Rebuilt every time the menu opens, so labels and jobs are current.
    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
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
        let jobs = JobCenter.shared.jobs
        if !jobs.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "處理中（點一下取消）", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for job in jobs {
                let pct = job.progress.map { "\(Int($0 * 100))%" } ?? "…"
                let item = NSMenuItem(title: "✕  \(job.title) · \(job.subject) — \(pct)", action: #selector(cancelJob(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = job
                menu.addItem(item)
            }
            if jobs.count > 1 {
                menu.addItem(withTitle: "全部取消", action: #selector(cancelAllJobs), keyEquivalent: "").target = self
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "新手教學…", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "GitHub 專案頁面", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 Marshmallow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
    }

    @objc private func cancelJob(_ sender: NSMenuItem) { (sender.representedObject as? Job)?.cancel() }
    @objc private func cancelAllJobs() { JobCenter.shared.cancelAll() }

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
    func menuNeedsUpdate(_ menu: NSMenu) { fillMenu(menu) }
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
        // Background-job check: Marshmallow --jobtest <convert-target> <cancelAfterSeconds|0> <file>
        if args.count >= 5, args[1] == "--jobtest" {
            setvbuf(stdout, nil, _IONBF, 0)
            app.setActivationPolicy(.prohibited)
            let wheel = WheelController()
            let file = URL(fileURLWithPath: args[4]); let target = args[2]; let cancelAfter = Double(args[3]) ?? 0
            let t0 = Date()
            func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
            var lastPct = -1
            let obs = wheel.model.$progress.sink { p in
                guard let p else { return }
                let pct = Int(p * 100)
                if pct / 25 != lastPct / 25 { lastPct = pct; print("\(stamp()) progress \(pct)%") }
            }
            let phaseObs = wheel.model.$phase.sink { print("\(stamp()) phase \($0)") }
            DispatchQueue.main.async {
                wheel.show(files: [file], mode: .convert, at: NSPoint(x: -20000, y: -20000))
                guard let idx = wheel.model.items.firstIndex(where: { $0.id == "convert.\(target)" }) else { print("no item"); exit(2) }
                wheel.perform(index: idx, files: [file])
                if cancelAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + cancelAfter) {
                        print("\(stamp()) cancelling via menu (\(JobCenter.shared.jobs.count) job)")
                        JobCenter.shared.cancelAll()
                    }
                }
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                    if JobCenter.shared.jobs.isEmpty, Date().timeIntervalSince(t0) > 0.5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("\(stamp()) done"); exit(0) }
                    }
                }
            }
            withExtendedLifetime((wheel, obs, phaseObs)) { app.run() }
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
