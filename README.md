<p align="center"><img src="docs/icon.png" width="128" alt="Marshmallow icon"></p>

<h1 align="center">Marshmallow 棉花糖</h1>

<p align="center">拖曳檔案時按住修飾鍵，就會跳出一個轉檔輪盤。把檔案丟到想要的格式上，就轉好了。<br>
macOS 原生、全部在本機處理、免費開源。</p>

---

## 怎麼用

1. 在 Finder（或任何 App）裡開始**拖曳**一個或多個檔案。
2. 拖曳中按住快捷鍵，輪盤就會出現在游標的位置：

| 快捷鍵（預設） | 輪盤 | 內容 |
|---|---|---|
| ⇧ Shift | **轉檔** | 依檔案類型列出可轉換的格式 |
| ⇧⌥ Shift + Option | **工具** | 壓縮、移除中繼資料、去背、裁切、遮蔽臉孔／文字… |
| ⇧⌘ Shift + Command | **動作** | AirDrop、訊息、郵件、拷貝、拷貝路徑、壓縮成 ZIP、合併 PDF… |

3. 移到想要的格子上**放開滑鼠**。輸出檔預設存在原檔旁邊，中央會顯示結果，也可以直接把結果拖出去。
4. 放在中央或輪盤外放開就是取消。

> 快捷鍵、輸出位置、品質都可以在選單列圖示的「設定…」裡修改。

## 支援格式

| 類型 | 轉檔 | 工具 |
|---|---|---|
| 圖片 | JPG、PNG、WEBP\*、HEIC、AVIF、PDF、TIFF、GIF、BMP、ICO、ICNS | 壓縮、移除中繼資料、去背（Vision）、加白底、遮蔽臉孔與文字、自動裁切、縮小 50%、旋轉 |
| 影片 | MP4、MOV、WEBM\*、GIF、HEVC、MKV\*、MP3\*、M4A、WAV | 壓縮、移除中繼資料、靜音、取出音訊、擷取畫面、720p、旋轉\*、2 倍速\* |
| 音訊 | MP3\*、M4A、WAV、FLAC\*、AIFF、OGG\*、OPUS\*、CAF | 壓縮、移除中繼資料、音量標準化\*、去除靜音\*、單聲道\*、2 倍速\*、反轉\* |
| PDF | PNG、JPG、DOCX、TXT、RTF、HTML、HEIC、TIFF | 壓縮、移除中繼資料、旋轉、拆頁、反轉頁序、擷取文字、灰階 |
| 文件（DOCX/DOC/RTF/ODT/HTML/TXT/MD） | PDF、DOCX、RTF、TXT、HTML、ODT、PNG、MD | 純文字、轉 PDF、字數統計 |

\* 需要 [Homebrew](https://brew.sh)：`brew install ffmpeg webp`。沒有安裝時，這些項目會自動隱藏，其他功能都用 macOS 內建框架（ImageIO、AVFoundation、PDFKit、Vision）處理。

## 安裝

從 [Releases](../../releases) 下載最新的 `Marshmallow-x.y.z.zip`，解壓縮後拖進「應用程式」。

App 沒有經過 Apple 公證，第一次開啟請在 App 上按右鍵 →「打開」，或執行：

```bash
xattr -dr com.apple.quarantine /Applications/Marshmallow.app
```

需求：macOS 14 以上（macOS 26 以上會使用 Liquid Glass 外觀）。不需要「輔助使用」權限。

## 從原始碼建置

```bash
scripts/build-app.sh          # 產生 build/Marshmallow.app 與 dist/Marshmallow-<版本>.zip
```

開發用的隱藏指令：

```bash
swift build
.build/debug/Marshmallow --list photo.jpg                       # 列出各輪盤的項目
.build/debug/Marshmallow --run convert convert.webp photo.jpg  # 不開 UI 直接執行某個項目
.build/debug/Marshmallow --demo tools 2 photo.jpg              # 在螢幕中央顯示輪盤（第 2 格 hover）
.build/debug/Marshmallow --selftest 0 85 photo.jpg             # 不用滑鼠模擬「移到某格再放開」
```

發布新版本：

```bash
scripts/release.sh 0.2.0 "更新內容…"
```

## 運作原理

- **偵測拖曳**：每秒輪詢 30 次滑鼠按鍵狀態。按下期間如果拖曳剪貼簿（`NSPasteboard(name: .drag)`）的 changeCount 改變，就代表有檔案拖曳開始；修飾鍵用 `NSEvent.modifierFlags` 讀取，所以不需要輔助使用權限。
- **選擇格子**：macOS 只會把拖曳交給「拖曳開始時已經在螢幕上」的視窗，所以輪盤不依賴系統的放置事件，而是自己追蹤游標位置。放開滑鼠時游標停在哪一格，就執行哪一格。
- **轉檔**：圖片用 ImageIO，影音用 ffmpeg 或 AVFoundation，文件用 NSAttributedString 和 PDFKit，去背和遮蔽用 Vision。

Marshmallow 是獨立撰寫的開源專案，受到拖曳轉檔類工具的操作方式啟發，沒有使用其他產品的程式碼或素材。

## 授權

[MIT](LICENSE)
