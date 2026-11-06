import AppKit
import UniformTypeIdentifiers

// MARK: - File classification

enum FileKind: String {
    case image, video, audio, pdf, document, spreadsheet, presentation, ebook, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "pages", "doc", "docx", "rtf", "rtfd", "odt", "txt", "text", "html", "htm", "webarchive", "wordml":
            return .document
        case "xlsx", "xls", "csv", "tsv", "numbers", "ods": return .spreadsheet
        case "pptx", "ppt", "key", "odp": return .presentation
        case "epub": return .ebook
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) || ext == "svg" { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .rtf) || type.conforms(to: .plainText) || type.conforms(to: .html) { return .document }
        return .other
    }

    /// Common kind for a group of files (`.other` when mixed).
    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.of))
        return kinds.count == 1 ? kinds.first! : .other
    }
}

// MARK: - Errors

struct MarshmallowError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Output naming

enum OutputNamer {
    /// e.g. "photo.png" -> "<dir>/photo.webp", "photo (compressed).png"; never overwrites.
    static func url(for source: URL, ext: String, suffix: String? = nil, directory: URL? = nil) -> URL {
        let dir = directory ?? Settings.shared.outputDirectory(for: source)
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix { base += " (\(suffix))" }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func folder(for source: URL, suffix: String) -> URL {
        let dir = Settings.shared.outputDirectory(for: source)
        let base = source.deletingPathExtension().lastPathComponent + " (\(suffix))"
        let url = unique(dir.appendingPathComponent(base, isDirectory: true))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

// MARK: - External tools (ffmpeg / cwebp from Homebrew)

enum ToolLocator {
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func reset() { lock.lock(); cache = [:]; lock.unlock() }

    static func path(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        var candidates: [String] = []
        if name == "ffmpeg" {
            let custom = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
            if !custom.isEmpty { candidates.append(custom) }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools/\(name)").path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cache[name] = found
        return found
    }

    static var ffmpeg: String? { path("ffmpeg") }
    static var cwebp: String? { path("cwebp") }
    static var hasFFmpeg: Bool { ffmpeg != nil }
}

// MARK: - Process helper

enum Shell {
    /// Runs a process. Cancelling the calling task terminates it.
    /// `onLine` receives output line by line (used for ffmpeg progress).
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        final class Box: @unchecked Sendable { var proc: Process?; var cancelled = false }
        let box = Box(); box.proc = p
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                final class Buffer: @unchecked Sendable { var data = Data(); var pending = Data() }
                let buf = Buffer()
                let q = DispatchQueue(label: "shell.read")
                out.fileHandleForReading.readabilityHandler = { h in
                    let chunk = h.availableData
                    q.sync {
                        buf.data.append(chunk)
                        guard let onLine else { return }
                        buf.pending.append(chunk)
                        while let nl = buf.pending.firstIndex(of: 0x0A) {
                            onLine(String(decoding: buf.pending[buf.pending.startIndex..<nl], as: UTF8.self))
                            buf.pending.removeSubrange(buf.pending.startIndex...nl)
                        }
                    }
                }
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    let rest = out.fileHandleForReading.readDataToEndOfFile()
                    let text: String = q.sync { buf.data.append(rest); return String(decoding: buf.data, as: UTF8.self) }
                    // Tools like ffmpeg catch SIGTERM and exit "normally", so rely on our own flag.
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        cont.resume(returning: text)
                    } else {
                        // Drop ffmpeg's `key=value` progress lines; keep the real error.
                        let lines = text.split(separator: "\n").filter { line in
                            !line.contains("=") || line.contains(" ") || line.hasPrefix("Error")
                        }
                        let tail = lines.suffix(3).joined(separator: "\n")
                        cont.resume(throwing: MarshmallowError("\((executable as NSString).lastPathComponent) 失敗：\(tail)"))
                    }
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            box.cancelled = true
            if box.proc?.isRunning == true { box.proc?.terminate() }
        }
    }

    /// Runs ffmpeg with `-y -hide_banner -loglevel error` prepended. The last
    /// argument must be the output path; it is deleted if the job is cancelled.
    /// With `duration`, progress is reported to the current job.
    static func ffmpeg(_ args: [String], duration: Double? = nil) async throws {
        guard let ff = ToolLocator.ffmpeg else {
            throw MarshmallowError("需要 ffmpeg：請執行 brew install ffmpeg")
        }
        var full = ["-y", "-hide_banner", "-loglevel", "error", "-nostdin"]
        var onLine: (@Sendable (String) -> Void)?
        if let duration, duration > 0, let job = JobContext.current {
            full += ["-progress", "pipe:1", "-nostats"]
            onLine = { line in
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                    job.report(min(1, max(0, us / 1_000_000 / duration)))
                }
            }
        }
        do {
            try await run(ff, full + args, onLine: onLine)
        } catch {
            if let out = args.last { try? FileManager.default.removeItem(atPath: out) }   // never leave half-written files
            if error is CancellationError { throw error }
            throw friendlyFFmpegError(error.localizedDescription)
        }
    }

    /// Plain-language versions of common ffmpeg failures.
    static func friendlyFFmpegError(_ raw: String) -> MarshmallowError {
        let map: [(String, String)] = [
            ("Invalid data found", "檔案好像壞掉了，或不是能辨識的影音格式。"),
            ("does not contain any stream", "這個檔案裡沒有可以轉換的影像或聲音。"),
            ("Output file does not contain any stream", "這個檔案裡沒有可以轉換的影像或聲音。"),
            ("matches no streams", "這個檔案沒有聲音軌，無法做這個操作。"),
            ("No space left on device", "磁碟空間不足。"),
            ("Permission denied", "沒有權限讀取或寫入這個位置。"),
            ("Unknown encoder", "你安裝的 ffmpeg 缺少需要的編碼器，請執行 brew reinstall ffmpeg。"),
        ]
        for (needle, msg) in map where raw.contains(needle) { return MarshmallowError(msg) }
        return MarshmallowError(raw)
    }
}

// MARK: - Misc

extension URL {
    var fileSizeString: String {
        let size = (try? resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]))
        if size?.isDirectory == true { return "資料夾" }
        return ByteCountFormatter.string(fromByteCount: Int64(size?.fileSize ?? 0), countStyle: .file)
    }
}
