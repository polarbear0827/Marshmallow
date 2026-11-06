import AppKit
import AVKit
import AVFoundation

/// Video/audio trimming using the system trim UI (same as QuickTime Player).
final class TrimEditor: NSObject, NSWindowDelegate {
    private static var open: [TrimEditor] = []
    let url: URL
    let window: NSWindow
    let playerView = AVPlayerView()

    static func present(_ url: URL) {
        let t = TrimEditor(url: url)
        open.append(t)
        NSApp.activate(ignoringOtherApps: true)
        t.window.makeKeyAndOrderFront(nil)
        t.beginTrim()
    }

    init(url: URL) {
        self.url = url
        let isAudio = FileKind.of(url) == .audio
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: isAudio ? 160 : 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "剪輯 — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        window.contentView = playerView
        window.center()
    }

    private func beginTrim() {
        // The trim UI becomes available once the item is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            guard self.playerView.canBeginTrimming else {
                if self.window.isVisible { self.beginTrim() }
                return
            }
            self.playerView.beginTrimming { result in
                if result == .okButton { self.export() } else { self.window.close() }
            }
        }
    }

    private func export() {
        guard let item = playerView.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime, end = item.forwardPlaybackEndTime
        let range = CMTimeRange(start: start.isValid ? start : .zero, end: end.isValid ? end : item.duration)
        let ext = url.pathExtension.lowercased()
        let isAudio = FileKind.of(url) == .audio
        window.title = "輸出中…"
        Task {
            do {
                let out: URL
                if ToolLocator.hasFFmpeg {
                    out = OutputNamer.url(for: url, ext: ext, suffix: "trimmed")
                    // Re-encode for frame-accurate cuts.
                    try await Shell.ffmpeg(["-ss", String(format: "%.3f", range.start.seconds), "-i", url.path,
                                            "-t", String(format: "%.3f", range.duration.seconds)] +
                                           (isAudio ? [] : ["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]) +
                                           [out.path])
                } else {
                    let type: AVFileType = isAudio ? .m4a : (ext == "mov" ? .mov : .mp4)
                    out = OutputNamer.url(for: url, ext: isAudio ? "m4a" : (ext == "mov" ? "mov" : "mp4"), suffix: "trimmed")
                    guard let s = AVAssetExportSession(asset: AVURLAsset(url: url),
                                                       presetName: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality) else {
                        throw MarshmallowError("無法建立輸出工作")
                    }
                    s.timeRange = range
                    if #available(macOS 15, *) { try await s.export(to: out, as: type) } else {
                        s.outputURL = out; s.outputFileType = type
                        await s.export()
                        if s.status != .completed { throw s.error ?? MarshmallowError("輸出失敗") }
                    }
                }
                await MainActor.run {
                    if Settings.shared.playSound { NSSound(named: "Pop")?.play() }
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                    self.window.close()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    self.window.close()
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        TrimEditor.open.removeAll { $0 === self }
    }
}
