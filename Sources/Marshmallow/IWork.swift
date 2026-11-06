import AppKit

/// High-fidelity Office conversions by scripting Pages, Numbers and Keynote
/// (the same approach Tangerine takes for Word files).
enum IWork {
    enum App: String {
        case pages = "Pages", numbers = "Numbers", keynote = "Keynote"
        var bundleID: String { "com.apple.iWork.\(rawValue)" }
        var isInstalled: Bool {
            if ProcessInfo.processInfo.environment["MM_NO_IWORK"] != nil { return false }  // testing native paths
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    /// AppleScript export format names, keyed by output extension.
    static func exportFormat(_ app: App, ext: String) -> String? {
        switch (app, ext) {
        case (_, "pdf"): return "PDF"
        case (.pages, "docx"): return "Microsoft Word"
        case (.pages, "epub"): return "EPUB"
        case (.pages, "txt"): return "unformatted text"
        case (.pages, "rtf"): return "formatted text"
        case (.pages, "pages"): return "Pages"
        case (.numbers, "xlsx"): return "Microsoft Excel"
        case (.numbers, "csv"): return "CSV"
        case (.numbers, "numbers"): return "Numbers"
        case (.keynote, "pptx"): return "Microsoft PowerPoint"
        case (.keynote, "key"): return "Keynote"
        case (.keynote, "mov"), (.keynote, "m4v"): return "QuickTime movie"
        case (.keynote, "html"): return "HTML"
        default: return nil
        }
    }

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs AppleScript against an iWork app, launching it hidden and quitting it
    /// afterwards if it wasn't already running.
    static func run(_ app: App, _ body: String) async throws {
        guard app.isInstalled else { throw MarshmallowError("需要 \(app.rawValue)（App Store 免費下載）") }
        // Serialize iWork jobs so one job's quit can't race the next job's launch.
        try await gate.run {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            let wasRunning = running.contains { !$0.isTerminated }
            if !wasRunning {
                try await Shell.run("/usr/bin/open", ["-g", "-j", "-b", app.bundleID])
            }
            let script = """
            with timeout of 900 seconds
            tell application id \(q(app.bundleID))
            \(body)
            end tell
            end timeout
            """
            var failure: Error?
            do {
                try await Shell.run("/usr/bin/osascript", ["-e", script])
            } catch {
                let msg = error.localizedDescription
                if msg.contains("-1743") || msg.contains("Not authorized") {
                    failure = MarshmallowError("請在「系統設定 → 隱私權與安全性 → 自動化」允許 Marshmallow 控制 \(app.rawValue)")
                } else {
                    failure = MarshmallowError("\(app.rawValue) 轉換失敗：\(msg)")
                }
            }
            if !wasRunning {
                // Quit only if no documents are left open, and wait until it's gone.
                _ = try? await Shell.run("/usr/bin/osascript", ["-e",
                    "tell application id \(q(app.bundleID)) to if (count of documents) is 0 then quit"])
                for _ in 0..<50 where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains(where: { !$0.isTerminated }) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let failure { throw failure }
        }
    }

    /// One iWork job at a time.
    private static let gate = AsyncGate()

    /// Opens `input` in the app and exports it as `ext`.
    static func export(_ input: URL, with app: App, ext: String, to out: URL) async throws {
        guard let format = exportFormat(app, ext: ext) else { throw MarshmallowError("\(app.rawValue) 不支援輸出 \(ext.uppercased())") }
        // Native iWork formats are written with `save`, everything else with `export`.
        let native = ["pages", "numbers", "key"].contains(ext)
        var asFormat = "as \(format)"
        if app == .keynote && ext == "pdf" { asFormat += " with properties {PDF image quality:Best}" }
        let write = native
            ? "save d in (POSIX file \(q(out.path)))"
            : "export d to (POSIX file \(q(out.path))) \(asFormat)"
        try await run(app, """
        set d to open (POSIX file \(q(input.path)))
        try
            delay 0.3
            \(write)
        on error errMsg number errNum
            close d saving no
            error errMsg number errNum
        end try
        close d saving no
        """)
        guard FileManager.default.fileExists(atPath: out.path) else { throw MarshmallowError("\(app.rawValue) 沒有產生輸出檔") }
    }

    /// Keynote: export every slide as an image into a folder.
    static func slideImages(_ input: URL, ext: String) async throws -> URL {
        let folder = OutputNamer.folder(for: input, suffix: ext.uppercased())
        let fmt = ext == "png" ? "PNG" : (ext == "tiff" ? "TIFF" : "JPEG")
        try await run(.keynote, """
        set d to open (POSIX file \(q(input.path)))
        try
            export d to (POSIX file \(q(folder.path))) as slide images with properties {image format:\(fmt), skipped slides:false}
        on error errMsg number errNum
            close d saving no
            error errMsg number errNum
        end try
        close d saving no
        """)
        return folder
    }

    /// Keynote: build a deck with one full-bleed image per slide, then export.
    static func deck(fromImages images: [URL], ext: String, to out: URL) async throws {
        let list = images.map { "POSIX file \(q($0.path))" }.joined(separator: ", ")
        try await run(.keynote, """
        set imgs to {\(list)}
        set d to make new document with properties {width:1920, height:1080}
        try
        tell d
            set firstSlide to slide 1
            repeat with i from 1 to count of imgs
                if i is 1 then
                    set s to firstSlide
                else
                    set s to make new slide
                end if
                tell s
                    try
                        delete every text item
                    end try
                    set img to make new image with properties {file:(item i of imgs)}
                    -- fit inside the slide, centred
                    set w to width of img
                    set h to height of img
                    set k to 1920 / w
                    if (h * k) > 1080 then set k to 1080 / h
                    set width of img to (w * k)
                    set height of img to (h * k)
                    set position of img to {(1920 - (w * k)) / 2, (1080 - (h * k)) / 2}
                end tell
            end repeat
        end tell
        on error errMsg number errNum
            close d saving no
            error errMsg number errNum
        end try
        \(ext == "key" ? "save d in (POSIX file \(q(out.path)))" : "export d to (POSIX file \(q(out.path))) as \(exportFormat(.keynote, ext: ext) ?? "Microsoft PowerPoint")")
        close d saving no
        """)
    }
}

/// Runs async jobs strictly one after another.
actor AsyncGate {
    private var tail: Task<Void, Never>?
    func run(_ job: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Result<Void, Error>, Never> {
            await previous?.value
            do { try await job(); return .success(()) } catch { return .failure(error) }
        }
        tail = Task { _ = await task.value }
        try await task.value.get()
    }
}
