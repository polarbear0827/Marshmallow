import AppKit

/// Result of running a wheel item.
enum ItemResult {
    case files([URL])
    case message(String)
}

struct WheelItem: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    /// Runs on a background task with all dropped files.
    let run: ([URL]) async throws -> ItemResult
}

enum Catalog {
    static let maxItems = 8

    static func items(mode: WheelMode, files: [URL]) -> [WheelItem] {
        guard !files.isEmpty else { return [] }
        let kind = FileKind.common(files)
        let exts = Set(files.map { $0.pathExtension.lowercased() })
        switch mode {
        case .convert: return Array(convertItems(kind: kind, excluding: exts).prefix(maxItems))
        case .tools: return Array(toolItems(kind: kind).prefix(maxItems))
        case .actions: return actionItems(files: files)
        }
    }

    // MARK: Convert

    /// Converts each file individually.
    private static func each(_ body: @escaping (URL) async throws -> URL) -> ([URL]) async throws -> ItemResult {
        { urls in
            var outs: [URL] = []
            for u in urls { outs.append(try await body(u)) }
            return .files(outs)
        }
    }

    private static func fmt(_ ext: String, title: String? = nil, _ body: @escaping (URL) async throws -> URL) -> WheelItem {
        WheelItem(id: "convert.\(ext)", title: title ?? ext.uppercased(), symbol: nil, run: each(body))
    }

    static func convertItems(kind: FileKind, excluding exts: Set<String>) -> [WheelItem] {
        func notSame(_ e: String) -> Bool {
            let same: [String: Set<String>] = ["jpg": ["jpg", "jpeg"], "tiff": ["tif", "tiff"], "html": ["html", "htm"]]
            return exts.isDisjoint(with: same[e] ?? [e])
        }
        switch kind {
        case .image:
            return ["jpg", "png", "webp", "heic", "avif", "pdf", "tiff", "gif", "bmp", "ico", "icns"]
                .filter(notSame)
                .filter { $0 != "webp" || ToolLocator.cwebp != nil || ToolLocator.hasFFmpeg }
                .map { ext in fmt(ext) { try ImageEngine.convert($0, to: ext) } }
        case .video:
            let all = ["mp4", "mov", "webm", "gif", "hevc", "mkv", "mp3", "m4a", "wav"]
            return all.filter(notSame)
                .filter { ToolLocator.hasFFmpeg || MediaEngine.nativeTargets.contains($0) }
                .map { t in fmt(t, title: t == "hevc" ? "HEVC" : nil) { try await MediaEngine.convert($0, to: t) } }
        case .audio:
            return ["mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "caf"].filter(notSame)
                .filter { ToolLocator.hasFFmpeg || MediaEngine.nativeTargets.contains($0) }
                .map { t in fmt(t) { try await MediaEngine.convert($0, to: t) } }
        case .pdf:
            return ["png", "jpg", "docx", "txt", "rtf", "html", "heic", "tiff"].map { t in
                fmt(t) { u in try await MainActor.run { try DocumentEngine.convert(u, to: t) } }
            }
        case .document:
            return ["pdf", "docx", "rtf", "txt", "html", "odt", "png", "md"].filter(notSame).map { t in
                fmt(t) { u in try await MainActor.run { try DocumentEngine.convert(u, to: t) } }
            }
        case .other:
            return []
        }
    }

    // MARK: Tools

    private static func tool(_ id: String, _ title: String, _ symbol: String, _ body: @escaping (URL) async throws -> URL) -> WheelItem {
        WheelItem(id: "tool.\(id)", title: title, symbol: symbol, run: each(body))
    }

    static func toolItems(kind: FileKind) -> [WheelItem] {
        switch kind {
        case .image:
            return [
                tool("compress", "COMPRESS", "arrow.down.right.and.arrow.up.left") { try ImageEngine.compress($0) },
                tool("metadata", "METADATA", "tag.slash") { try ImageEngine.stripMetadata($0) },
                tool("removebg", "REMOVE BG", "person.crop.rectangle") {
                    try ImageEngine.transform($0, suffix: "no bg", forceExt: "png") { try ImageEngine.removeBackground($0) }
                },
                tool("addbg", "ADD BG", "photo.fill") {
                    try ImageEngine.transform($0, suffix: "white bg") { ImageEngine.flatten($0, background: .white) }
                },
                tool("redact", "REDACT", "eye.slash") {
                    try ImageEngine.transform($0, suffix: "redacted") { try ImageEngine.redact($0) }
                },
                tool("crop", "CROP", "crop") {
                    try ImageEngine.transform($0, suffix: "cropped") { ImageEngine.autoCrop($0) }
                },
                tool("resize", "RESIZE 50%", "arrow.down.left.and.arrow.up.right") {
                    try ImageEngine.transform($0, suffix: "50%") { ImageEngine.scaled($0, factor: 0.5) }
                },
                tool("rotate", "ROTATE", "rotate.right") {
                    try ImageEngine.transform($0, suffix: "rotated") { ImageEngine.rotated90($0) }
                },
                tool("flip", "FLIP", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    try ImageEngine.transform($0, suffix: "flipped") { ImageEngine.flippedHorizontally($0) }
                },
                tool("gray", "GRAYSCALE", "circle.lefthalf.filled") {
                    try ImageEngine.transform($0, suffix: "grayscale") { ImageEngine.grayscale($0) }
                },
            ]
        case .video, .audio:
            typealias T = MediaEngine.Tool
            let video: [(T, String, String)] = [
                (.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left"),
                (.metadata, "METADATA", "tag.slash"),
                (.mute, "MUTE", "speaker.slash"),
                (.extractAudio, "AUDIO", "waveform"),
                (.snapshot, "SNAPSHOT", "camera"),
                (.resize720, "720P", "arrow.down.left.and.arrow.up.right"),
                (.rotate, "ROTATE", "rotate.right"),
                (.speed2x, "2× SPEED", "hare"),
            ]
            let audio: [(T, String, String)] = [
                (.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left"),
                (.metadata, "METADATA", "tag.slash"),
                (.normalize, "NORMALIZE", "slider.horizontal.3"),
                (.trimSilence, "TRIM SILENCE", "scissors"),
                (.mono, "MONO", "speaker.wave.1"),
                (.speed2x, "2× SPEED", "hare"),
                (.reverse, "REVERSE", "backward"),
            ]
            let native = MediaEngine.nativeTools(for: kind)
            return (kind == .video ? video : audio)
                .filter { ToolLocator.hasFFmpeg || native.contains($0.0) }
                .map { t in tool(t.0.rawValue, t.1, t.2) { try await MediaEngine.apply(t.0, to: $0) } }
        case .pdf:
            typealias P = DocumentEngine.PDFTool
            let list: [(P, String, String, String)] = [
                (.compress, "compress", "COMPRESS", "arrow.down.right.and.arrow.up.left"),
                (.metadata, "metadata", "METADATA", "tag.slash"),
                (.rotate, "rotate", "ROTATE", "rotate.right"),
                (.split, "split", "SPLIT", "square.split.2x1"),
                (.reverse, "reverse", "REVERSE", "arrow.up.arrow.down"),
                (.extractText, "text", "TEXT", "text.alignleft"),
                (.grayscale, "gray", "GRAYSCALE", "circle.lefthalf.filled"),
            ]
            return list.map { t in tool(t.1, t.2, t.3) { u in try DocumentEngine.apply(t.0, to: u) } }
        case .document:
            return [
                tool("plain", "PLAIN TEXT", "text.alignleft") { u in
                    try await MainActor.run { try DocumentEngine.convert(u, to: "txt") }
                },
                tool("pdf", "TO PDF", "doc.richtext") { u in
                    try await MainActor.run { try DocumentEngine.convert(u, to: "pdf") }
                },
                WheelItem(id: "tool.count", title: "WORD COUNT", symbol: "number") { urls in
                    var words = 0, chars = 0
                    for u in urls {
                        let s = try await MainActor.run { try DocumentEngine.attributedString(from: u).string }
                        words += s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                        chars += s.count
                    }
                    let msg = "\(words) 字詞 · \(chars) 字元"
                    await MainActor.run {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg, forType: .string)
                    }
                    return .message(msg)
                },
            ]
        case .other:
            return []
        }
    }

    // MARK: Actions

    static func actionItems(files: [URL]) -> [WheelItem] {
        var items: [WheelItem] = [
            share("airdrop", "AIRDROP", "dot.radiowaves.up.forward", .sendViaAirDrop),
            share("messages", "MESSAGES", "message", .composeMessage),
            share("mail", "MAIL", "envelope", .composeEmail),
            WheelItem(id: "action.copy", title: "COPY", symbol: "doc.on.doc") { urls in
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(urls as [NSURL])
                }
                return .message("已複製 \(urls.count) 個檔案")
            },
            WheelItem(id: "action.path", title: "COPY PATH", symbol: "link") { urls in
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
                return .message("已複製路徑")
            },
            WheelItem(id: "action.zip", title: "ZIP", symbol: "archivebox") { urls in
                .files([try await zip(urls)])
            },
            WheelItem(id: "action.duplicate", title: "DUPLICATE", symbol: "plus.square.on.square") { urls in
                var outs: [URL] = []
                for u in urls {
                    let dest = OutputNamer.unique(u.deletingLastPathComponent().appendingPathComponent(u.deletingPathExtension().lastPathComponent + " copy").appendingPathExtension(u.pathExtension))
                    try FileManager.default.copyItem(at: u, to: dest)
                    outs.append(dest)
                }
                return .files(outs)
            },
        ]
        let mergeable = files.allSatisfy { [.image, .pdf].contains(FileKind.of($0)) }
        if files.count > 1 && mergeable {
            items.append(WheelItem(id: "action.merge", title: "MERGE PDF", symbol: "doc.on.doc.fill") { urls in
                .files([try DocumentEngine.merge(urls)])
            })
        } else {
            items.append(WheelItem(id: "action.reveal", title: "REVEAL", symbol: "folder") { urls in
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                return .message("已在 Finder 顯示")
            })
        }
        return items
    }

    private static func share(_ id: String, _ title: String, _ symbol: String, _ name: NSSharingService.Name) -> WheelItem {
        WheelItem(id: "action.\(id)", title: title, symbol: symbol) { urls in
            try await MainActor.run {
                guard let service = NSSharingService(named: name), service.canPerform(withItems: urls) else {
                    throw MarshmallowError("無法使用 \(title)")
                }
                NSApp.activate(ignoringOtherApps: true)
                service.perform(withItems: urls)
            }
            return .message("已開啟 \(title.capitalized)")
        }
    }

    static func zip(_ urls: [URL]) async throws -> URL {
        guard let first = urls.first else { throw MarshmallowError("沒有檔案") }
        let dir = Settings.shared.outputDirectory(for: first)
        if urls.count == 1 {
            let out = OutputNamer.unique(dir.appendingPathComponent(first.deletingPathExtension().lastPathComponent + ".zip"))
            try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            return out
        }
        let out = OutputNamer.unique(dir.appendingPathComponent("Archive.zip"))
        // Stage copies via hard links/copies in a temp folder so files from different folders work.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("mm-zip-\(UUID().uuidString)/Archive")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        for u in urls {
            try FileManager.default.copyItem(at: u, to: OutputNamer.unique(stage.appendingPathComponent(u.lastPathComponent)))
        }
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, out.path])
        return out
    }
}
