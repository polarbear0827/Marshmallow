import AppKit
import SwiftUI
import Carbon.HIToolbox   // AEDeterminePermissionToAutomateTarget
import UserNotifications

// MARK: - Window

final class OnboardingWindow: NSObject, NSWindowDelegate {
    private static var shared: OnboardingWindow?
    let window: NSWindow
    let model = OnboardingModel()

    /// Shows the tutorial (reusing the open one).
    static func show() {
        if shared == nil { shared = OnboardingWindow() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window.makeKeyAndOrderFront(nil)
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "歡迎使用 Marshmallow"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, close: { [weak self] in self?.window.close() }))
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        OnboardingWindow.shared = nil
    }
}

// MARK: - Model

enum AutomationState: Equatable {
    case notInstalled, unknown, granted, denied, checking
    var label: String {
        switch self {
        case .notInstalled: return "未安裝"
        case .unknown: return "尚未授權"
        case .granted: return "已授權"
        case .denied: return "已拒絕"
        case .checking: return "檢查中…"
        }
    }
}

final class OnboardingModel: ObservableObject {
    static let practiceModes: [WheelMode] = [.convert, .tools, .actions]
    static let stepCount = 6   // welcome, permissions, 3 practices, done

    @Published var step = 0
    @Published var done: [WheelMode: String] = [:]          // mode -> what the user picked
    @Published var automation: [IWork.App: AutomationState] = [:]
    @Published var launchAtLogin = Settings.shared.launchAtLogin
    @Published var dontShowAgain = !Settings.shared.showOnboarding
    @Published var notificationsGranted = false
    let practiceFile: URL
    private var observer: Any?

    init() {
        practiceFile = OnboardingModel.makePracticeFile()
        for app in [IWork.App.pages, .numbers, .keynote] {
            automation[app] = app.isInstalled ? .checking : .notInstalled
        }
        refreshAutomation()
        refreshNotifications()
        observer = NotificationCenter.default.addObserver(forName: .wheelItemFinished, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?["mode"] as? String, let mode = WheelMode(rawValue: raw),
                  note.userInfo?["success"] as? Bool == true else { return }
            let title = note.userInfo?["title"] as? String ?? ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { self.done[mode] = title }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var practiceMode: WheelMode? {
        (2...4).contains(step) ? OnboardingModel.practiceModes[step - 2] : nil
    }

    // MARK: Practice file

    /// A cute sample image to drag around, kept in Application Support.
    static func makePracticeFile() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marshmallow/練習", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("練習檔案.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = NSSize(width: 600, height: 600)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.72, alpha: 1),
                                NSColor(srgbRed: 0.78, green: 0.64, blue: 1.0, alpha: 1)])!.draw(in: r, angle: -35)
            for (x, y, w) in [(110.0, 200.0, 170.0), (320.0, 230.0, 180.0), (210.0, 340.0, 150.0)] {
                let rect = NSRect(x: x, y: y, width: w, height: w * 0.9)
                NSColor.white.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: rect, xRadius: w * 0.3, yRadius: w * 0.3).fill()
                NSColor(srgbRed: 1, green: 0.93, blue: 0.95, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 8, y: rect.maxY - w * 0.3, width: w - 16, height: w * 0.26)).fill()
            }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            ("練習檔案" as NSString).draw(in: NSRect(x: 0, y: 70, width: 600, height: 80), withAttributes: [
                .font: NSFont.systemFont(ofSize: 60, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para,
            ])
            return true
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }

    // MARK: Automation permission

    func refreshAutomation() {
        for app in [IWork.App.pages, .numbers, .keynote] where app.isInstalled {
            let status = OnboardingModel.automationStatus(app.bundleID, ask: false)
            automation[app] = OnboardingModel.state(for: status)
        }
    }

    static func state(for status: OSStatus) -> AutomationState {
        switch Int(status) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted: return .denied
        default: return .unknown          // -1744 needs consent, -600 not running, …
        }
    }

    static func automationStatus(_ bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let data = Array(bundleID.utf8)
        let created = data.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, data.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    /// Launches the app hidden (the check needs it running), asks, then quits it again.
    func requestAutomation(_ app: IWork.App) {
        automation[app] = .checking
        Task.detached {
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
            if !wasRunning {
                _ = try? await Shell.run("/usr/bin/open", ["-g", "-j", "-b", app.bundleID])
                for _ in 0..<50 where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            let status = OnboardingModel.automationStatus(app.bundleID, ask: true)
            if !wasRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
            }
            await MainActor.run { self.automation[app] = OnboardingModel.state(for: status) }
        }
    }

    func requestNotifications() {
        JobCenter.shared.requestNotificationPermission { [weak self] ok in self?.notificationsGranted = ok }
    }

    func refreshNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { self.notificationsGranted = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional }
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

// MARK: - Root view

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: WelcomePage()
                case 1: PermissionsPage(model: model)
                case 2, 3, 4: PracticePage(model: model, mode: OnboardingModel.practiceModes[model.step - 2])
                default: DonePage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .id(model.step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            Divider()
            HStack(spacing: 14) {
                Toggle("不再顯示新手教學", isOn: $model.dontShowAgain)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.dontShowAgain) { _, v in Settings.shared.showOnboarding = !v }
                Spacer()
                StepDots(current: model.step, count: OnboardingModel.stepCount)
                Spacer()
                if model.step > 0 {
                    Button("上一步") { go(-1) }
                }
                if model.step < OnboardingModel.stepCount - 1 {
                    Button(nextTitle) { go(1) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(WheelView.accent)
                } else {
                    Button("開始使用") { close() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(WheelView.accent)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 560)
    }

    private var nextTitle: String {
        if let mode = model.practiceMode, model.done[mode] == nil { return "略過" }
        return model.step == 0 ? "開始" : "下一步"
    }

    private func go(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.28)) {
            model.step = min(max(0, model.step + d), OnboardingModel.stepCount - 1)
        }
        if model.step == 1 { model.refreshAutomation() }
    }
}

struct StepDots: View {
    let current: Int, count: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? WheelView.accent : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3), value: current)
    }
}

// MARK: - Pages

struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 120, height: 120)
                .shadow(color: WheelView.accent.opacity(0.4), radius: 18, y: 8)
            Text("歡迎使用 Marshmallow 棉花糖").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("拖曳檔案的時候按住一個按鍵，就會跳出輪盤。\n把檔案丟到想要的格子上，轉檔、編輯、分享一次搞定。")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ShortcutChip(keys: "⇧", name: "Shift", action: "轉檔", color: .pink)
                ShortcutChip(keys: "⌘", name: "Command", action: "工具", color: .purple)
                ShortcutChip(keys: "⌃", name: "Control", action: "動作", color: .orange)
            }
            .padding(.top, 8)
            Text("接下來會帶你設定權限，並實際練習這三種輪盤，大約一分鐘。")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
    }
}

struct ShortcutChip: View {
    let keys: String, name: String, action: String, color: Color
    var body: some View {
        VStack(spacing: 6) {
            KeyCap(symbol: keys, name: name)
            Text("＋拖曳 → \(action)").font(.system(size: 13, weight: .semibold))
        }
        .padding(14)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.25)))
    }
}

struct KeyCap: View {
    let symbol: String, name: String
    var pressed = false
    var body: some View {
        HStack(spacing: 6) {
            Text(symbol).font(.system(size: 20, weight: .semibold))
            Text(name).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(pressed ? WheelView.accent : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(pressed ? 0.05 : 0.18), radius: 0, y: pressed ? 0 : 2.5)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.3)))
        .foregroundStyle(pressed ? .white : .primary)
        .offset(y: pressed ? 2 : 0)
    }
}

struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @State private var toolsRefresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("設定權限").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Marshmallow 不需要「輔助使用」或「螢幕錄製」權限，所有轉檔都在你的 Mac 上完成。以下都是選用項目。")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("轉換 Word、Excel、PowerPoint 檔案", systemImage: "doc.richtext").font(.headline)
                    Text("Marshmallow 會透過 Pages、Numbers、Keynote 轉換 Office 檔，排版最準確。按「授權」後 macOS 會詢問一次，請選「好」。")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach([IWork.App.pages, .numbers, .keynote], id: \.self) { app in
                        HStack {
                            Text(app.rawValue).frame(width: 80, alignment: .leading)
                            statusBadge(model.automation[app] ?? .unknown)
                            Spacer()
                            switch model.automation[app] ?? .unknown {
                            case .unknown: Button("授權") { model.requestAutomation(app) }
                            case .denied: Button("打開系統設定") { model.openAutomationSettings() }
                            case .notInstalled:
                                Button("App Store") {
                                    NSWorkspace.shared.open(URL(string: "macappstore://search?term=\(app.rawValue)")!)
                                }
                            default: EmptyView()
                            }
                        }
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("轉檔完成通知", systemImage: "bell.badge").font(.headline)
                        Spacer()
                        if model.notificationsGranted {
                            Label("已允許", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        } else {
                            Button("允許通知") { model.requestNotifications() }
                        }
                    }
                    Text("影片等比較久的轉檔會在背景進行，完成時用通知告訴你。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle(isOn: $model.launchAtLogin) {
                        Label("登入 Mac 時自動啟動 Marshmallow", systemImage: "power").font(.headline)
                    }
                    .onChange(of: model.launchAtLogin) { _, v in Settings.shared.launchAtLogin = v }
                    Divider()
                    Label("更多影音格式（選用）", systemImage: "film").font(.headline)
                    HStack {
                        statusBadge(ToolLocator.ffmpeg != nil ? .granted : .unknown, okText: "ffmpeg 已安裝", missingText: "ffmpeg 未安裝")
                        statusBadge(ToolLocator.cwebp != nil ? .granted : .unknown, okText: "cwebp 已安裝", missingText: "cwebp 未安裝")
                        Spacer()
                        if ToolLocator.ffmpeg == nil || ToolLocator.cwebp == nil {
                            Button("拷貝安裝指令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install ffmpeg webp", forType: .string)
                            }
                            Button("重新偵測") { ToolLocator.reset(); toolsRefresh += 1 }
                        }
                    }
                    .id(toolsRefresh)
                    Text("在終端機執行 brew install ffmpeg webp 後，可以轉 WEBM、MP3、FLAC、OGG、WebP 等格式。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusBadge(_ s: AutomationState, okText: String? = nil, missingText: String? = nil) -> some View {
        let (icon, color): (String, Color) = {
            switch s {
            case .granted: return ("checkmark.circle.fill", .green)
            case .denied: return ("xmark.octagon.fill", .red)
            case .notInstalled: return ("minus.circle", .secondary)
            case .checking: return ("clock", .secondary)
            case .unknown: return ("exclamationmark.circle", .orange)
            }
        }()
        let text = s == .granted ? (okText ?? s.label) : (s == .unknown ? (missingText ?? s.label) : s.label)
        Label(text, systemImage: icon).foregroundStyle(color).font(.callout)
    }
}

struct PracticePage: View {
    @ObservedObject var model: OnboardingModel
    let mode: WheelMode

    private var info: (symbol: String, name: String, title: String, target: String, hint: String) {
        switch mode {
        case .convert: return ("⇧", "Shift", "轉檔", "PDF", "例如移到「PDF」或「JPG」再放開，就會在練習檔案旁產生轉好的檔案。")
        case .tools: return ("⌘", "Command", "工具", "COMPRESS", "例如移到「COMPRESS」壓縮，或「ANNOTATE」打開標註視窗。")
        case .actions: return ("⌃", "Control", "動作", "COPY PATH", "例如移到「COPY PATH」拷貝路徑，或「FLOAT」放到浮動視窗。")
        }
    }

    var body: some View {
        let i = info
        let finished = model.done[mode]
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text("練習 \(model.step - 1)／3").font(.callout.weight(.semibold)).foregroundStyle(WheelView.accent)
                HStack(spacing: 10) {
                    KeyCap(symbol: i.symbol, name: i.name)
                    Text("＋ 拖曳 → \(i.title)").font(.system(size: 24, weight: .bold, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "按住右邊的「練習檔案」，開始拖曳。")
                    step(2, "拖曳中再按住 \(i.symbol) \(i.name)，輪盤就會出現。")
                    step(3, "移到想要的格子上，放開滑鼠。")
                }
                Text(i.hint).font(.callout).foregroundStyle(.secondary)
                if mode == .actions {
                    Label("請先開始拖曳再按 ⌃。若先按著 ⌃ 再點，會變成右鍵選單。", systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                resultBanner(finished)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                DemoAnimation(mode: mode, symbol: i.symbol, name: i.name, target: i.target)
                    .frame(width: 250, height: 190)
                PracticeCard(url: model.practiceFile)
                    .frame(width: 150, height: 150)
                Text("練習檔案（拖我！）").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 260)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(WheelView.accent.opacity(0.18)))
            Text(text).font(.body)
        }
    }

    @ViewBuilder
    private func resultBanner(_ finished: String?) -> some View {
        if let finished {
            Label("成功！你剛剛用了「\(finished)」。可以繼續下一步了。", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.12)))
                .transition(.scale.combined(with: .opacity))
        } else {
            Label("等你試試看…", systemImage: "hand.point.up.left")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        }
    }
}

struct DonePage: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 64))
                .foregroundStyle(WheelView.accent)
            Text("準備好了！").font(.system(size: 30, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(OnboardingModel.practiceModes, id: \.self) { m in
                    HStack {
                        Image(systemName: model.done[m] != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.done[m] != nil ? .green : .secondary)
                        Text(line(m))
                    }
                }
            }
            .font(.title3)
            Text("Marshmallow 會待在選單列（棉花糖圖示）。想重看教學或修改快捷鍵，點選單列圖示就可以找到「新手教學…」和「設定…」。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Spacer()
        }
    }
    private func line(_ m: WheelMode) -> String {
        switch m {
        case .convert: return "⇧ Shift ＋ 拖曳 → 轉檔"
        case .tools: return "⌘ Command ＋ 拖曳 → 工具"
        case .actions: return "⌃ Control ＋ 拖曳 → 動作"
        }
    }
}

// MARK: - Demo animation (looping illustration of the gesture)

struct DemoAnimation: View {
    let mode: WheelMode
    let symbol: String, name: String, target: String

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2)
            let dragProgress = min(1, max(0, t / 0.9))                  // file starts moving
            let keyDown = t > 0.9 && t < 3.6                             // key held
            let wheelOn = t > 1.2 && t < 3.7
            let toSegment = min(1, max(0, (t - 1.6) / 0.7))              // move onto segment
            let hit = t > 2.3 && t < 3.6
            let filePos = CGPoint(x: 70 + 55 * dragProgress, y: 100 - 62 * toSegment)
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.07))
                MiniWheel(highlight: hit)
                    .scaleEffect(wheelOn ? 1 : 0.6)
                    .opacity(wheelOn ? 1 : 0)
                    .position(x: 125, y: 98)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: wheelOn)
                Image(nsImage: NSWorkspace.shared.icon(for: .png))
                    .resizable().frame(width: 34, height: 34)
                    .shadow(radius: 2)
                    .position(filePos)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 16, weight: .bold))
                    .position(x: filePos.x + 12, y: filePos.y + 14)
                KeyCap(symbol: symbol, name: name, pressed: keyDown)
                    .scaleEffect(0.8)
                    .position(x: 125, y: 172)
                    .animation(.easeOut(duration: 0.12), value: keyDown)
                if hit {
                    Text(target).font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(WheelView.accent))
                        .foregroundStyle(.white)
                        .position(x: 125, y: 14)
                }
            }
        }
    }
}

/// A small static wheel used in the demo.
struct MiniWheel: View {
    var highlight: Bool
    var body: some View {
        let n = 7
        ZStack {
            Circle().fill(Color.secondary.opacity(0.15))
                .frame(width: WheelGeometry.outerRadius * 2, height: WheelGeometry.outerRadius * 2)
            ForEach(0..<n, id: \.self) { i in
                SegmentShape(index: i, count: n)
                    .fill(i == 0 && highlight ? WheelView.accent : Color.white.opacity(0.85))
            }
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .scaleEffect(0.5)
        .frame(width: WheelGeometry.size * 0.5, height: WheelGeometry.size * 0.5)
    }
}

// MARK: - Draggable practice file

struct PracticeCard: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PracticeDragView { PracticeDragView(url: url) }
    func updateNSView(_ v: PracticeDragView, context: Context) {}
}

final class PracticeDragView: NSView, NSDraggingSource {
    let url: URL
    private let image: NSImage

    init(url: URL) {
        self.url = url
        image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 8, dy: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.set()
        let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        NSColor.white.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // aspect-fill
        let s = max(r.width / image.size.width, r.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        image.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 40, y: p.y - 30, width: 80, height: 60), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy   // the practice file is never moved
    }
}
