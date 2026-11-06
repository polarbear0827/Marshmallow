# Marshmallow 開發者說明

> 一般使用者請看 [README](../README.md)，這份文件是給想修改或建置原始碼的人。

需求：macOS 14 以上、Xcode（Swift 5.10+）。

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
scripts/release.sh 0.3.0 "更新內容…"
```

## 運作原理

- **偵測拖曳**：每秒輪詢 60 次滑鼠按鍵狀態。按下期間如果拖曳剪貼簿（`NSPasteboard(name: .drag)`）的 changeCount 改變，就代表有檔案拖曳開始；修飾鍵用 `NSEvent.modifierFlags` 讀取，所以不需要輔助使用權限。
- **接住放置**：macOS 只會把拖曳交給「拖曳開始時已經在螢幕上」的視窗。所以滑鼠一按下，Marshmallow 就在按下的位置放一個完全透明、點擊可穿透的面板。之後真的開始拖曳並按下快捷鍵時，輪盤就在同一個位置顯示，並接住放置，檔案不會掉到底下的視窗。輪盤只接受「拷貝」操作；按著 ⌘（搬移）或 ⌃（替身）時會拒絕放置，讓檔案滑回原位，再由「放開滑鼠」的偵測執行你選的項目，所以原檔永遠不會被搬動。
- **轉檔**：圖片用 ImageIO，影音用 ffmpeg 或 AVFoundation，文件用 NSAttributedString 和 PDFKit，Office 檔用 Pages／Numbers／Keynote 的 AppleScript（也有內建的 XLSX／CSV／EPUB／DOCX 讀寫器），去背和遮蔽用 Vision。

- **新手教學**：第一次啟動（以及每次啟動，直到勾選「不再顯示新手教學」）會開啟教學視窗。練習頁會監聽輪盤完成時發出的 `wheelItemFinished` 通知來打勾。

## 示範動畫

`docs/demo-*.gif` 是用真實的 App 錄的：用 `screencapture -v` 錄一個展示視窗，再用 ffmpeg 裁切並轉成 GIF。
