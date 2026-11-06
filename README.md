<p align="center"><img src="docs/icon.png" width="128" alt="Marshmallow icon"></p>

<h1 align="center">Marshmallow 棉花糖</h1>

<p align="center">拖曳檔案時按住修飾鍵，就會跳出一個轉檔輪盤。把檔案丟到想要的格式上，就轉好了。<br>
macOS 原生、全部在本機處理、免費開源。</p>

---

## 怎麼用

1. 在 Finder（或任何 App）裡開始**拖曳**一個或多個檔案。
2. 拖曳中按住快捷鍵，輪盤會以拖曳起點為中心出現。中央是透明的，可以看到原本的檔案：

| 快捷鍵（預設，與 Tangerine 相同） | 輪盤 | 內容 |
|---|---|---|
| ⇧ Shift | **轉檔** | 依檔案類型列出可轉換的格式 |
| ⌘ Command | **工具** | 壓縮、移除中繼資料、編輯、標註、加背景、裁切、遮蔽、剪輯、合併… |
| ⌃ Control | **動作** | AirDrop、浮動視窗、拷貝路徑、終端機、拷貝、ZIP、訊息、郵件 |

3. 移到想要的格子上**放開滑鼠**。輸出檔預設存在原檔旁邊，中央會顯示結果，也可以直接把結果拖出去。
4. 放在中央或輪盤外放開就是取消。**原始檔案永遠不會被搬移或修改**，即使按著 ⌘ 也一樣。

> 快捷鍵、輸出位置、品質都可以在選單列圖示的「設定…」裡修改。

## 支援格式

| 類型 | 轉檔 | 工具（⌘） |
|---|---|---|
| 圖片 | JPG、PNG、WEBP\*、HEIC、TIFF、AVIF、BMP、PDF、DOCX、GIF、ICO、ICNS | 壓縮、移除中繼資料、**編輯**（曝光／對比／飽和度／色溫／銳利度／旋轉／縮放）、**標註**（畫筆、螢光筆、方框、圓、箭頭、文字）、**加背景**（漸層、留白、圓角、陰影、自動去背）、**裁切**（自由或固定比例）、**遮蔽**（馬賽克／黑條／模糊，可自動偵測臉孔與文字） |
| 影片 | MP4、MOV、WEBM\*、GIF、HEVC、MKV\*、MP3\*、M4A、WAV | 壓縮、移除中繼資料、**剪輯**、靜音、取出音訊、擷取畫面、720p、旋轉\* |
| 音訊 | MP3\*、M4A、WAV、FLAC\*、AIFF、OGG\*、OPUS\*、CAF | 壓縮、移除中繼資料、**剪輯**、音量標準化\*、去除靜音\*、單聲道\*、2 倍速\*、反轉\* |
| PDF | PNG、JPG、DOCX、PPTX†、TXT、EPUB、HTML、RTF | 壓縮、移除中繼資料、旋轉、拆頁、反轉頁序、擷取文字、灰階；多個檔案可**合併** |
| Word／文件（DOCX、DOC、Pages、RTF、ODT、TXT、MD、HTML） | PDF、DOCX、Pages†、EPUB、RTF、TXT、HTML、MD | 純文字、轉 PDF、字數統計 |
| Excel／試算表（XLSX、XLS、CSV、TSV、Numbers、ODS） | XLSX、PDF、CSV、Numbers†、HTML、JSON、TSV、MD | — |
| PowerPoint／簡報（PPTX、PPT、Key、ODP） | PDF、PPTX、Key、PNG、JPG、MP4、HTML（需要 Keynote） | — |
| EPUB | PDF、DOCX、TXT、HTML、RTF、MD、Pages†、ODT | — |

\* 需要 [Homebrew](https://brew.sh)：`brew install ffmpeg webp`。
† 需要 Pages／Numbers／Keynote（App Store 免費）。Word、Excel、PowerPoint 檔有安裝 iWork 時會透過 iWork 轉換，排版最準確；第一次使用時 macOS 會詢問是否允許 Marshmallow 控制這些 App。沒有安裝時會改用內建的轉換器。

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
.build/debug/Marshmallow --editor-test crop photo.jpg          # 在螢幕外開啟編輯器並儲存
MM_NO_IWORK=1 .build/debug/Marshmallow --run convert convert.pdf report.docx  # 強制使用內建轉換器
```

發布新版本：

```bash
scripts/release.sh 0.2.0 "更新內容…"
```

## 運作原理

- **偵測拖曳**：每秒輪詢 60 次滑鼠按鍵狀態。按下期間如果拖曳剪貼簿（`NSPasteboard(name: .drag)`）的 changeCount 改變，就代表有檔案拖曳開始；修飾鍵用 `NSEvent.modifierFlags` 讀取，所以不需要輔助使用權限。
- **接住放置**：macOS 只會把拖曳交給「拖曳開始時已經在螢幕上」的視窗。所以滑鼠一按下，Marshmallow 就在按下的位置放一個完全透明、點擊可穿透的面板。之後真的開始拖曳並按下快捷鍵時，輪盤就在同一個位置顯示，並接住放置，檔案不會掉到底下的視窗。輪盤只接受「拷貝」操作；按著 ⌘（搬移）或 ⌃（替身）時會拒絕放置，讓檔案滑回原位，再由「放開滑鼠」的偵測執行你選的項目，所以原檔永遠不會被搬動。
- **轉檔**：圖片用 ImageIO，影音用 ffmpeg 或 AVFoundation，文件用 NSAttributedString 和 PDFKit，Office 檔用 Pages／Numbers／Keynote 的 AppleScript（也有內建的 XLSX／CSV／EPUB／DOCX 讀寫器），去背和遮蔽用 Vision。

Marshmallow 是獨立撰寫的開源專案，受到拖曳轉檔類工具的操作方式啟發，沒有使用其他產品的程式碼或素材。

## 授權

[MIT](LICENSE)
