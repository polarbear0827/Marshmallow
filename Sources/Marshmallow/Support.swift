import AppKit
import UniformTypeIdentifiers

// MARK: - File classification

enum FileKind: String {
    case image, video, audio, pdf, document, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) || ext == "svg" { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        let docExts = ["doc", "docx", "rtf", "rtfd", "odt", "txt", "text", "html", "htm", "webarchive", "wordml"]
        if docExts.contains(ext) || type.conforms(to: .rtf) || type.conforms(to: .plainText) || type.conforms(to: .html) {
            return .document
        }
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
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            final class Buffer: @unchecked Sendable { var data = Data() }
            let buf = Buffer()
            let q = DispatchQueue(label: "shell.read")
            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                q.sync { buf.data.append(chunk) }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                let text: String = q.sync { buf.data.append(rest); return String(decoding: buf.data, as: UTF8.self) }
                if proc.terminationStatus == 0 {
                    cont.resume(returning: text)
                } else {
                    let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n")
                    cont.resume(throwing: MarshmallowError("\((executable as NSString).lastPathComponent) 失敗：\(tail)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Runs ffmpeg with `-y -hide_banner -loglevel error` prepended.
    static func ffmpeg(_ args: [String]) async throws {
        guard let ff = ToolLocator.ffmpeg else {
            throw MarshmallowError("需要 ffmpeg：請執行 brew install ffmpeg")
        }
        try await run(ff, ["-y", "-hide_banner", "-loglevel", "error", "-nostdin"] + args)
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
