import SwiftUI

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @State private var launchAtLogin = Settings.shared.launchAtLogin
    @State private var toolsRefresh = 0

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Marshmallow 棉花糖").font(.title2.bold())
                        Text("拖曳檔案時按住修飾鍵，就會出現轉檔輪盤。把檔案拖到想要的格式上放開即可。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("一般") {
                Toggle("啟用拖曳輪盤", isOn: $s.enabled)
                Toggle("登入時自動啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in s.launchAtLogin = v }
                Toggle("完成時播放音效", isOn: $s.playSound)
                Toggle("完成後在 Finder 中顯示", isOn: $s.revealAfter)
                LabeledContent("結果停留秒數") {
                    Stepper(value: $s.hideDelay, in: 1...15, step: 1) { Text("\(Int(s.hideDelay)) 秒") }
                }
            }

            Section {
                Picker("轉檔輪盤", selection: $s.convertCombo) { ForEach(ModifierCombo.allCases) { Text($0.label).tag($0) } }
                Picker("工具輪盤", selection: $s.toolsCombo) { ForEach(ModifierCombo.allCases) { Text($0.label).tag($0) } }
                Picker("動作輪盤", selection: $s.actionsCombo) { ForEach(ModifierCombo.allCases) { Text($0.label).tag($0) } }
            } header: {
                Text("快捷鍵（拖曳中按住）")
            } footer: {
                Text("提示：Finder 拖曳時單按 ⌘ 會變成「搬移」、單按 ⌥ 會變成「拷貝」，因此預設都搭配 ⇧ Shift。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("輸出") {
                Picker("儲存位置", selection: $s.outputLocation) { ForEach(OutputLocation.allCases) { Text($0.label).tag($0) } }
                if s.outputLocation == .custom {
                    HStack {
                        Text(s.customFolder.isEmpty ? "尚未選擇" : s.customFolder)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("選擇…") { chooseFolder() }
                    }
                }
                LabeledContent("有損格式品質") {
                    HStack {
                        Slider(value: $s.quality, in: 0.3...1.0)
                        Text("\(Int(s.quality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
            }

            Section {
                toolRow("ffmpeg", path: ToolLocator.ffmpeg, purpose: "影片/音訊轉檔（WEBM、MP3、FLAC…）")
                toolRow("cwebp", path: ToolLocator.cwebp, purpose: "輸出 WebP 圖片")
                if ToolLocator.ffmpeg == nil || ToolLocator.cwebp == nil {
                    HStack {
                        Text("brew install ffmpeg webp").font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button("複製指令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install ffmpeg webp", forType: .string)
                        }
                        Button("重新偵測") { ToolLocator.reset(); toolsRefresh += 1 }
                    }
                }
            } header: {
                Text("外部工具（選用）")
            } footer: {
                Text("沒有這些工具時，Marshmallow 仍可用 macOS 內建框架處理 JPG/PNG/HEIC/AVIF/TIFF/PDF、MP4/MOV/M4A/WAV 等格式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .id(toolsRefresh)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func toolRow(_ name: String, path: String?, purpose: String) -> some View {
        HStack {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? .orange : .green)
            VStack(alignment: .leading) {
                Text(name).bold()
                Text(path ?? purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url { s.customFolder = url.path }
    }
}
