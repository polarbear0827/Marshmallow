import AppKit
import ServiceManagement

/// Which wheel is shown.
enum WheelMode: String, CaseIterable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "轉檔 Convert"
        case .tools: return "工具 Tools"
        case .actions: return "動作 Actions"
        }
    }
}

/// Modifier combinations a wheel can be bound to.
enum ModifierCombo: String, CaseIterable, Identifiable {
    case shift, command, control, option, shiftOption, shiftCommand, shiftControl, controlOption, disabled
    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .shift: return [.shift]
        case .command: return [.command]
        case .option: return [.option]
        case .shiftOption: return [.shift, .option]
        case .shiftCommand: return [.shift, .command]
        case .shiftControl: return [.shift, .control]
        case .control: return [.control]
        case .controlOption: return [.control, .option]
        case .disabled: return nil
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .shiftOption: return "⇧⌥ Shift + Option"
        case .shiftCommand: return "⇧⌘ Shift + Command"
        case .shiftControl: return "⇧⌃ Shift + Control"
        case .control: return "⌃ Control"
        case .controlOption: return "⌃⌥ Control + Option"
        case .disabled: return "停用 Disabled"
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case sameFolder, downloads, desktop, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sameFolder: return "與原檔相同資料夾"
        case .downloads: return "下載項目 Downloads"
        case .desktop: return "桌面 Desktop"
        case .custom: return "自訂資料夾…"
        }
    }
}

/// Thin typed wrapper around UserDefaults.
final class Settings: ObservableObject {
    /// Defaults must be registered before any stored property reads UserDefaults.
    static let shared: Settings = {
        registerDefaults()
        return Settings()
    }()
    private let d = UserDefaults.standard

    private init() {}

    private static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "enabled": true,
            "convertCombo": ModifierCombo.shift.rawValue,
            "toolsCombo": ModifierCombo.command.rawValue,
            "actionsCombo": ModifierCombo.control.rawValue,
            "outputLocation": OutputLocation.sameFolder.rawValue,
            "quality": 0.85,
            "playSound": true,
            "revealAfter": false,
            "hideDelay": 4.0,
            "didOnboard": false,
            "showOnboarding": true,
            "keepCaptureInfo": true,
        ])
    }

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "enabled") {
        didSet { d.set(enabled, forKey: "enabled") }
    }
    @Published var convertCombo: ModifierCombo = ModifierCombo(rawValue: UserDefaults.standard.string(forKey: "convertCombo") ?? "") ?? .shift {
        didSet { d.set(convertCombo.rawValue, forKey: "convertCombo") }
    }
    @Published var toolsCombo: ModifierCombo = ModifierCombo(rawValue: UserDefaults.standard.string(forKey: "toolsCombo") ?? "") ?? .command {
        didSet { d.set(toolsCombo.rawValue, forKey: "toolsCombo") }
    }
    @Published var actionsCombo: ModifierCombo = ModifierCombo(rawValue: UserDefaults.standard.string(forKey: "actionsCombo") ?? "") ?? .control {
        didSet { d.set(actionsCombo.rawValue, forKey: "actionsCombo") }
    }
    @Published var outputLocation: OutputLocation = OutputLocation(rawValue: UserDefaults.standard.string(forKey: "outputLocation") ?? "") ?? .sameFolder {
        didSet { d.set(outputLocation.rawValue, forKey: "outputLocation") }
    }
    @Published var customFolder: String = UserDefaults.standard.string(forKey: "customFolder") ?? "" {
        didSet { d.set(customFolder, forKey: "customFolder") }
    }
    @Published var quality: Double = UserDefaults.standard.double(forKey: "quality") {
        didSet { d.set(quality, forKey: "quality") }
    }
    @Published var playSound: Bool = UserDefaults.standard.bool(forKey: "playSound") {
        didSet { d.set(playSound, forKey: "playSound") }
    }
    @Published var revealAfter: Bool = UserDefaults.standard.bool(forKey: "revealAfter") {
        didSet { d.set(revealAfter, forKey: "revealAfter") }
    }
    @Published var hideDelay: Double = UserDefaults.standard.double(forKey: "hideDelay") {
        didSet { d.set(hideDelay, forKey: "hideDelay") }
    }
    @Published var ffmpegPath: String = UserDefaults.standard.string(forKey: "ffmpegPath") ?? "" {
        didSet { d.set(ffmpegPath, forKey: "ffmpegPath"); ToolLocator.reset() }
    }
    /// Keep capture date & camera model when converting (location is always removed).
    @Published var keepCaptureInfo: Bool = UserDefaults.standard.bool(forKey: "keepCaptureInfo") {
        didSet { d.set(keepCaptureInfo, forKey: "keepCaptureInfo") }
    }
    /// Show the tutorial at launch until the user ticks「不再顯示」.
    @Published var showOnboarding: Bool = UserDefaults.standard.bool(forKey: "showOnboarding") {
        didSet { d.set(showOnboarding, forKey: "showOnboarding") }
    }
    var didOnboard: Bool {
        get { d.bool(forKey: "didOnboard") }
        set { d.set(newValue, forKey: "didOnboard") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Marshmallow: launch at login failed: \(error)")
            }
        }
    }

    /// Returns the wheel bound to exactly this modifier set.
    func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let relevant = flags.intersection([.shift, .option, .command, .control])
        if relevant.isEmpty { return nil }
        // Check the more specific combos first.
        let pairs: [(WheelMode, ModifierCombo)] = [(.tools, toolsCombo), (.actions, actionsCombo), (.convert, convertCombo)]
        for (mode, combo) in pairs {
            if let f = combo.flags, f == relevant { return mode }
        }
        return nil
    }

    /// Folder where results for `source` should go.
    func outputDirectory(for source: URL) -> URL {
        let fm = FileManager.default
        switch outputLocation {
        case .sameFolder:
            let dir = source.deletingLastPathComponent()
            return fm.isWritableFile(atPath: dir.path) ? dir : fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop:
            return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .custom:
            if !customFolder.isEmpty { return URL(fileURLWithPath: customFolder, isDirectory: true) }
            return source.deletingLastPathComponent()
        }
    }
}
