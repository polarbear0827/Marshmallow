import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Video & audio conversions. Uses ffmpeg when available, AVFoundation otherwise.
enum MediaEngine {
    // MARK: Conversion targets

    static func ffmpegArgs(forTarget ext: String, sourceIsVideo: Bool) -> [String] {
        switch ext {
        case "mp4", "m4v":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case "hevc":
            return ["-c:v", "libx265", "-crf", "24", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "mkv":
            return ["-c:v", "libx264", "-crf", "20", "-c:a", "aac", "-b:a", "192k"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "gif":
            return ["-vf", "fps=12,scale='min(720,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4", "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg", "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        default: return []
        }
    }

    static func convert(_ url: URL, to target: String) async throws -> URL {
        let ext = target == "hevc" ? "mp4" : target
        let out = OutputNamer.url(for: url, ext: ext, suffix: target == "hevc" ? "HEVC" : nil)
        let isVideo = FileKind.of(url) == .video
        if ToolLocator.hasFFmpeg {
            try await ff(url, ["-i", url.path] + ffmpegArgs(forTarget: target, sourceIsVideo: isVideo) + [out.path])
            return out
        }
        // AVFoundation fallbacks
        switch target {
        case "mp4", "m4v": try await export(url, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: out)
        case "mov": try await export(url, preset: AVAssetExportPresetHighestQuality, type: .mov, to: out)
        case "hevc": try await export(url, preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, to: out)
        case "m4a": try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out)
        case "wav", "aiff", "caf": try await pcmExport(url, to: out, format: target)
        case "gif": try await videoToGIF(url, to: out)
        default: throw MarshmallowError("轉成 \(target.uppercased()) 需要 ffmpeg：brew install ffmpeg")
        }
        return out
    }

    /// Targets that work without ffmpeg.
    static let nativeTargets: Set<String> = ["mp4", "m4v", "mov", "hevc", "m4a", "wav", "aiff", "caf", "gif"]

    // MARK: Tools

    enum Tool: String { case compress, metadata, mute, resize720, rotate, extractAudio, snapshot, speed2x, normalize, trimSilence, mono, reverse }

    static func nativeTools(for kind: FileKind) -> Set<Tool> {
        kind == .video ? [.compress, .metadata, .extractAudio, .snapshot, .mute] : [.compress, .metadata]
    }

    static func apply(_ tool: Tool, to url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let isVideo = FileKind.of(url) == .video
        if ToolLocator.hasFFmpeg {
            let i = ["-i", url.path]
            switch tool {
            case .compress:
                if isVideo {
                    let out = OutputNamer.url(for: url, ext: "mp4", suffix: "compressed")
                    try await ff(url, i + ["-vf", "scale='min(1920,iw)':-2", "-c:v", "libx264", "-crf", "28", "-preset", "slow", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out.path])
                    return out
                } else {
                    let out = OutputNamer.url(for: url, ext: "m4a", suffix: "compressed")
                    try await ff(url, i + ["-vn", "-c:a", "aac", "-b:a", "96k", out.path])
                    return out
                }
            case .metadata:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "no metadata")
                try await Shell.ffmpeg(i + ["-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact", "-c", "copy", out.path])
                return out
            case .mute:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "muted")
                try await ff(url, i + ["-c", "copy", "-an", out.path])
                return out
            case .resize720:
                let out = OutputNamer.url(for: url, ext: ext == "webm" ? "webm" : "mp4", suffix: "720p")
                let codec = ext == "webm" ? ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0"] : ["-c:v", "libx264", "-crf", "21", "-pix_fmt", "yuv420p"]
                try await ff(url, i + ["-vf", "scale=-2:'min(720,ih)'"] + codec + ["-c:a", "copy", out.path])
                return out
            case .rotate:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "rotated")
                try await ff(url, i + ["-vf", "transpose=1", "-c:a", "copy", out.path])
                return out
            case .extractAudio:
                let out = OutputNamer.url(for: url, ext: "m4a")
                try await ff(url, i + ["-vn", "-c:a", "aac", "-b:a", "192k", out.path])
                return out
            case .snapshot:
                let out = OutputNamer.url(for: url, ext: "png", suffix: "frame")
                let dur = try await duration(url)
                try await ff(url, ["-ss", String(format: "%.2f", dur / 2), "-i", url.path, "-frames:v", "1", out.path])
                return out
            case .speed2x:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "2x")
                if isVideo, try await hasAudio(url) {
                    try await ff(url, i + ["-filter_complex", "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]", "-map", "[v]", "-map", "[a]", out.path])
                } else {
                    try await ff(url, i + (isVideo ? ["-vf", "setpts=0.5*PTS"] : ["-af", "atempo=2.0"]) + [out.path])
                }
                return out
            case .normalize:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "normalized")
                try await ff(url, i + ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000"] + (isVideo ? ["-c:v", "copy"] : []) + [out.path])
                return out
            case .trimSilence:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "trimmed")
                try await ff(url, i + ["-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse", out.path])
                return out
            case .mono:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "mono")
                try await ff(url, i + ["-ac", "1"] + (isVideo ? ["-c:v", "copy"] : []) + [out.path])
                return out
            case .reverse:
                let out = OutputNamer.url(for: url, ext: ext, suffix: "reversed")
                try await ff(url, i + (isVideo ? ["-vf", "reverse", "-af", "areverse"] : ["-af", "areverse"]) + [out.path])
                return out
            }
        }

        // Native fallbacks
        switch tool {
        case .compress:
            if isVideo {
                let out = OutputNamer.url(for: url, ext: "mp4", suffix: "compressed")
                try await export(url, preset: AVAssetExportPresetMediumQuality, type: .mp4, to: out)
                return out
            }
            let out = OutputNamer.url(for: url, ext: "m4a", suffix: "compressed")
            try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out)
            return out
        case .metadata:
            let type: AVFileType = ext == "mov" ? .mov : (isVideo ? .mp4 : .m4a)
            let outExt = type == .mov ? "mov" : (isVideo ? "mp4" : "m4a")
            let out = OutputNamer.url(for: url, ext: outExt, suffix: "no metadata")
            try await export(url, preset: AVAssetExportPresetPassthrough, type: type, to: out, stripMetadata: true)
            return out
        case .extractAudio:
            let out = OutputNamer.url(for: url, ext: "m4a")
            try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out)
            return out
        case .snapshot:
            let out = OutputNamer.url(for: url, ext: "png", suffix: "frame")
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            let dur = try await asset.load(.duration)
            let (img, _) = try await gen.image(at: CMTimeMultiplyByFloat64(dur, multiplier: 0.5))
            try ImageEngine.save(img, to: out)
            return out
        case .mute:
            let out = OutputNamer.url(for: url, ext: "mov", suffix: "muted")
            let asset = AVURLAsset(url: url)
            let comp = AVMutableComposition()
            let dur = try await asset.load(.duration)
            for track in try await asset.loadTracks(withMediaType: .video) {
                let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: .zero)
                t?.preferredTransform = try await track.load(.preferredTransform)
            }
            try await export(comp, preset: AVAssetExportPresetPassthrough, type: .mov, to: out)
            return out
        default:
            throw MarshmallowError("這個工具需要 ffmpeg：brew install ffmpeg")
        }
    }

    // MARK: Privacy

    /// Runs ffmpeg with metadata handling inserted before the output path:
    /// capture date/camera kept (per settings), GPS location always removed.
    static func ff(_ input: URL, _ args: [String]) async throws {
        var a = args
        a.insert(contentsOf: await privacyArgs(input), at: max(0, a.count - 1))
        try await Shell.ffmpeg(a)
    }

    static func privacyArgs(_ input: URL) async -> [String] {
        guard Settings.shared.keepCaptureInfo else { return ["-map_metadata", "-1"] }
        var a = ["-map_metadata", "0"]
        for key in ["location", "location-eng", "com.apple.quicktime.location.ISO6709", "com.apple.quicktime.location.name"] {
            a += ["-metadata", "\(key)="]
        }
        if let item = try? await AVURLAsset(url: input).load(.creationDate),
           let date = try? await item.load(.dateValue) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            a += ["-metadata", "creation_time=\(f.string(from: date))"]
        }
        return a
    }

    // MARK: AVFoundation helpers

    static func hasAudio(_ url: URL) async throws -> Bool {
        !(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty
    }

    static func duration(_ url: URL) async throws -> Double {
        let d = try await AVURLAsset(url: url).load(.duration)
        return d.seconds.isFinite ? d.seconds : 0
    }

    static func export(_ url: URL, preset: String, type: AVFileType, to out: URL, stripMetadata: Bool = false) async throws {
        try await export(AVURLAsset(url: url), preset: preset, type: type, to: out, stripMetadata: stripMetadata)
    }

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, to out: URL, stripMetadata: Bool = false) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MarshmallowError("無法建立轉檔工作")
        }
        // `.forSharing()` removes location and other identifying items but keeps dates.
        session.metadataItemFilter = .forSharing()
        if stripMetadata || !Settings.shared.keepCaptureInfo { session.metadata = [] }
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15, *) {
            try await session.export(to: out, as: type)
        } else {
            session.outputURL = out
            session.outputFileType = type
            await session.export()
            if session.status != .completed {
                throw session.error ?? MarshmallowError("轉檔失敗")
            }
        }
    }

    static func pcmExport(_ url: URL, to out: URL, format: String) async throws {
        let input = try AVAudioFile(forReading: url)
        let fmt = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == "aiff",
        ]
        if format == "caf" { settings[AVLinearPCMIsBigEndianKey] = false }
        let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 16)!
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    static func videoToGIF(_ url: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        let fps = 10.0
        let frames = max(1, min(Int(dur * fps), 300))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw MarshmallowError("無法建立 GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<frames {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (img, _) = try? await gen.image(at: t) { CGImageDestinationAddImage(dest, img, frameProps) }
        }
        guard CGImageDestinationFinalize(dest) else { throw MarshmallowError("寫入 GIF 失敗") }
    }
}
