import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Model

enum EditorMode: String {
    case edit, annotate, crop, redact, addBackground

    var title: String {
        switch self {
        case .edit: return "編輯"
        case .annotate: return "標註"
        case .crop: return "裁切"
        case .redact: return "遮蔽"
        case .addBackground: return "加背景"
        }
    }
    var suffix: String {
        switch self {
        case .edit: return "edited"
        case .annotate: return "annotated"
        case .crop: return "cropped"
        case .redact: return "redacted"
        case .addBackground: return "background"
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen, highlighter, rectangle, ellipse, arrow, text
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "character.textbox"
        }
    }
    var label: String {
        switch self {
        case .pen: return "畫筆"
        case .highlighter: return "螢光筆"
        case .rectangle: return "方框"
        case .ellipse: return "圓形"
        case .arrow: return "箭頭"
        case .text: return "文字"
        }
    }
}

/// A shape in image pixel coordinates (top-left origin).
struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
}

enum RedactStyle: String, CaseIterable, Identifiable {
    case pixelate, black, blur
    var id: String { rawValue }
    var label: String { ["pixelate": "馬賽克", "black": "黑條", "blur": "模糊"][rawValue]! }
}

struct Backdrop: Identifiable {
    let id: Int
    let colors: [NSColor]   // 1 = solid, 2 = gradient, 0 = transparent
    static let all: [Backdrop] = [
        Backdrop(id: 0, colors: [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.72, alpha: 1), NSColor(srgbRed: 0.78, green: 0.64, blue: 1.0, alpha: 1)]),
        Backdrop(id: 1, colors: [NSColor(srgbRed: 1.0, green: 0.55, blue: 0.25, alpha: 1), NSColor(srgbRed: 1.0, green: 0.3, blue: 0.4, alpha: 1)]),
        Backdrop(id: 2, colors: [NSColor(srgbRed: 0.25, green: 0.6, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.45, green: 0.9, blue: 0.85, alpha: 1)]),
        Backdrop(id: 3, colors: [NSColor(srgbRed: 0.2, green: 0.2, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)]),
        Backdrop(id: 4, colors: [NSColor(srgbRed: 0.55, green: 0.85, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.95, green: 0.9, blue: 0.4, alpha: 1)]),
        Backdrop(id: 5, colors: [.white]),
        Backdrop(id: 6, colors: [.black]),
        Backdrop(id: 7, colors: []),
    ]
}

final class ImageEditorModel: ObservableObject {
    let url: URL
    let mode: EditorMode
    let original: CGImage
    var imageSize: CGSize { CGSize(width: original.width, height: original.height) }

    // Edit
    @Published var exposure: Double = 0
    @Published var contrast: Double = 1
    @Published var saturation: Double = 1
    @Published var warmth: Double = 0
    @Published var sharpness: Double = 0
    @Published var quarterTurns = 0
    @Published var flipH = false
    @Published var scalePercent: Double = 100

    // Annotate
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow
    @Published var color: Color = .red
    @Published var lineWidth: Double = 6
    @Published var pendingText = "文字"

    // Crop
    @Published var crop: CGRect
    @Published var aspect: Double? = nil

    // Redact
    @Published var redactions: [CGRect] = []
    @Published var redactStyle: RedactStyle = .pixelate

    // Add background
    @Published var padding: Double = 0.12
    @Published var backdrop = 0
    @Published var corner: Double = 0.03
    @Published var shadow = true
    @Published var removeSubjectBackground = false
    private var cutout: CGImage?

    @Published var preview: CGImage
    @Published var busy = false

    init(url: URL, mode: EditorMode) throws {
        self.url = url
        self.mode = mode
        original = try ImageEngine.load(url)
        crop = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        preview = original
        refreshPreview()
    }

    // MARK: Rendering

    private let ci = CIContext()

    /// Applies colour adjustments (EDIT).
    func adjusted(_ img: CGImage) -> CGImage {
        var c = CIImage(cgImage: img)
        if exposure != 0 { let f = CIFilter.exposureAdjust(); f.inputImage = c; f.ev = Float(exposure); c = f.outputImage ?? c }
        if contrast != 1 || saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = c; f.contrast = Float(contrast); f.saturation = Float(saturation); c = f.outputImage ?? c
        }
        if warmth != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = c
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 6500 + warmth * 3000, y: 0)
            c = f.outputImage ?? c
        }
        if sharpness > 0 { let f = CIFilter.sharpenLuminance(); f.inputImage = c; f.sharpness = Float(sharpness); c = f.outputImage ?? c }
        let extent = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        var out = ci.createCGImage(c.cropped(to: extent), from: extent) ?? img
        for _ in 0..<(quarterTurns % 4) { out = ImageEngine.rotated90(out) }
        if flipH { out = ImageEngine.flippedHorizontally(out) }
        if scalePercent != 100 { out = ImageEngine.scaled(out, factor: scalePercent / 100) }
        return out
    }

    func refreshPreview() {
        switch mode {
        case .edit:
            let small = ImageEngine.fit(original, maxSide: 1400)
            let saved = scalePercent
            scalePercent = 100
            preview = adjusted(small)
            scalePercent = saved
        case .addBackground:
            let base = removeSubjectBackground ? (cutout ?? original) : original
            preview = composeBackground(ImageEngine.fit(base, maxSide: 1200))
        default:
            preview = original
        }
    }

    func toggleCutout() {
        guard removeSubjectBackground, cutout == nil else { refreshPreview(); return }
        busy = true
        let src = original
        DispatchQueue.global(qos: .userInitiated).async {
            let c = try? ImageEngine.removeBackground(src)
            DispatchQueue.main.async {
                self.cutout = c
                if c == nil { self.removeSubjectBackground = false }
                self.busy = false
                self.refreshPreview()
            }
        }
    }

    func composeBackground(_ img: CGImage) -> CGImage {
        let side = Double(max(img.width, img.height))
        let pad = Int(side * padding)
        let W = img.width + pad * 2, H = img.height + pad * 2
        guard let ctx = ImageEngine.bitmapContext(width: W, height: H) else { return img }
        let bd = Backdrop.all[backdrop]
        if bd.colors.count == 1 {
            ctx.setFillColor(bd.colors[0].cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        } else if bd.colors.count == 2,
                  let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: bd.colors.map(\.cgColor) as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        }
        let rect = CGRect(x: pad, y: pad, width: img.width, height: img.height)
        let radius = CGFloat(side * corner)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow && !removeSubjectBackground {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.04, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if !removeSubjectBackground { ctx.addPath(path); ctx.clip() }
        else if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.draw(img, in: rect)
        ctx.restoreGState()
        return ctx.makeImage() ?? img
    }

    /// Draws annotations onto an image (coordinates in image pixels, top-left origin).
    static func draw(_ annotations: [Annotation], on img: CGImage) -> CGImage {
        guard let ctx = ImageEngine.bitmapContext(width: img.width, height: img.height) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.translateBy(x: 0, y: CGFloat(img.height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for a in annotations { Self.stroke(a, in: ctx) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? img
    }

    static func stroke(_ a: Annotation, in ctx: CGContext) {
        guard let first = a.points.first else { return }
        let last = a.points.last ?? first
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineWidth(a.width)
        var color = a.color
        if a.tool == .highlighter { color = color.withAlphaComponent(0.4); ctx.setLineWidth(a.width * 3); ctx.setBlendMode(.multiply) }
        ctx.setStrokeColor(color.cgColor)
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        switch a.tool {
        case .pen, .highlighter:
            ctx.addLines(between: a.points); ctx.strokePath()
        case .rectangle:
            ctx.stroke(rect)
        case .ellipse:
            ctx.strokeEllipse(in: rect)
        case .arrow:
            ctx.move(to: first); ctx.addLine(to: last); ctx.strokePath()
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(14, a.width * 3.5)
            ctx.setFillColor(color.cgColor)
            ctx.move(to: last)
            ctx.addLine(to: CGPoint(x: last.x - head * cos(angle - .pi / 7), y: last.y - head * sin(angle - .pi / 7)))
            ctx.addLine(to: CGPoint(x: last.x - head * cos(angle + .pi / 7), y: last.y - head * sin(angle + .pi / 7)))
            ctx.closePath(); ctx.fillPath()
        case .text:
            let font = NSFont.systemFont(ofSize: max(14, a.width * 5), weight: .bold)
            (a.text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: color])
        }
        ctx.restoreGState()
    }

    func redacted(_ img: CGImage) -> CGImage {
        guard !redactions.isEmpty else { return img }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let input = CIImage(cgImage: img)
        var effect: CIImage
        switch redactStyle {
        case .pixelate:
            let f = CIFilter.pixellate(); f.inputImage = input.clampedToExtent(); f.scale = Float(max(12, min(W, H) / 40))
            effect = f.outputImage ?? input
        case .blur:
            let f = CIFilter.gaussianBlur(); f.inputImage = input.clampedToExtent(); f.radius = Float(max(10, min(W, H) / 50))
            effect = f.outputImage ?? input
        case .black:
            effect = CIImage(color: .black)
        }
        effect = effect.cropped(to: input.extent)
        var mask = CIImage(color: .clear).cropped(to: input.extent)
        for r in redactions {
            // model rects are top-left origin; CoreImage is bottom-left.
            let flipped = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            mask = CIImage(color: .white).cropped(to: flipped).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = effect; blend.backgroundImage = input; blend.maskImage = mask
        guard let out = blend.outputImage, let cg = ci.createCGImage(out, from: input.extent) else { return img }
        return cg
    }

    func autoDetectRedactions() {
        busy = true
        let img = original
        DispatchQueue.global(qos: .userInitiated).async {
            let faces = VNDetectFaceRectanglesRequest()
            let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: img).perform([faces, text])
            let W = CGFloat(img.width), H = CGFloat(img.height)
            let boxes = ((faces.results ?? []).map(\.boundingBox) + (text.results ?? []).map(\.boundingBox)).map {
                CGRect(x: $0.minX * W, y: (1 - $0.maxY) * H, width: $0.width * W, height: $0.height * H).insetBy(dx: -4, dy: -4)
            }
            DispatchQueue.main.async {
                self.redactions += boxes
                self.busy = false
            }
        }
    }

    // MARK: Output

    func render() -> CGImage {
        switch mode {
        case .edit: return adjusted(original)
        case .annotate: return Self.draw(annotations, on: original)
        case .crop: return original.cropping(to: crop.integral) ?? original
        case .redact: return redacted(original)
        case .addBackground: return composeBackground(removeSubjectBackground ? (cutout ?? original) : original)
        }
    }

    func save() throws -> URL {
        var ext = url.pathExtension.lowercased()
        if ImageEngine.utType(forExt: ext) == nil || ["gif", "ico", "icns", "svg"].contains(ext) { ext = "png" }
        if mode == .addBackground && Backdrop.all[backdrop].colors.isEmpty { ext = "png" }
        let out = OutputNamer.url(for: url, ext: ext, suffix: mode.suffix)
        // Redaction is about privacy, so it never carries capture info over.
        try ImageEngine.save(render(), to: out, quality: 0.95,
                             metadata: mode == .redact ? nil : ImageEngine.captureInfo(from: url))
        return out
    }
}

// MARK: - Window

final class ImageEditorWindow: NSObject, NSWindowDelegate {
    private static var open: [ImageEditorWindow] = []
    let window: NSWindow

    static func present(_ url: URL, mode: EditorMode) throws {
        let model = try ImageEditorModel(url: url, mode: mode)
        let w = ImageEditorWindow(model: model)
        open.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
    }

    /// Test hook: opens the editor off-screen without activating, pre-filled with sample edits.
    static func presentForTest(_ url: URL, mode: EditorMode) throws -> (NSWindow, ImageEditorModel) {
        let model = try ImageEditorModel(url: url, mode: mode)
        let s = model.imageSize
        switch mode {
        case .edit: model.exposure = 0.5; model.saturation = 1.6; model.quarterTurns = 1
        case .annotate:
            model.annotations = [
                Annotation(tool: .arrow, points: [CGPoint(x: s.width * 0.15, y: s.height * 0.8), CGPoint(x: s.width * 0.45, y: s.height * 0.45)], color: .systemRed, width: 10),
                Annotation(tool: .rectangle, points: [CGPoint(x: s.width * 0.5, y: s.height * 0.2), CGPoint(x: s.width * 0.85, y: s.height * 0.5)], color: .systemYellow, width: 8),
                Annotation(tool: .text, points: [CGPoint(x: s.width * 0.1, y: s.height * 0.1)], color: .white, width: 10, text: "棉花糖 Marshmallow"),
            ]
        case .crop: model.aspect = 1; model.crop = CGRect(x: (s.width - s.height) / 2, y: 0, width: s.height, height: s.height)
        case .redact: model.redactions = [CGRect(x: s.width * 0.3, y: s.height * 0.3, width: s.width * 0.4, height: s.height * 0.25)]
        case .addBackground: break
        }
        model.refreshPreview()
        let w = ImageEditorWindow(model: model)
        open.append(w)
        w.window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.window.orderFrontRegardless()
        return (w.window, model)
    }

    init(model: ImageEditorModel) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "\(model.mode.title) — \(model.url.lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView = NSHostingView(rootView: ImageEditorView(model: model, close: { [weak self] in self?.window.close() }))
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        ImageEditorWindow.open.removeAll { $0 === self }
    }
}

// MARK: - Views

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            EditorCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(model.mode.title).font(.title2.bold())
                ScrollView { controls.frame(maxWidth: .infinity, alignment: .leading) }
                Spacer(minLength: 0)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("儲存") {
                        do {
                            let out = try model.save()
                            if Settings.shared.playSound { NSSound(named: "Pop")?.play() }
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                            close()
                        } catch { self.error = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(WheelView.accent)
                }
            }
            .padding(18)
            .padding(.top, 20)
            .frame(width: 270)
        }
        .overlay { if model.busy { ProgressView().controlSize(.large) } }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.mode {
        case .edit: EditControls(model: model)
        case .annotate: AnnotateControls(model: model)
        case .crop: CropControls(model: model)
        case .redact: RedactControls(model: model)
        case .addBackground: BackgroundControls(model: model)
        }
    }
}

private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%.2f", onEnd: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            .font(.callout)
        Slider(value: value, in: range, onEditingChanged: { editing in if !editing { onEnd() } })
    }
}

struct EditControls: View {
    @ObservedObject var model: ImageEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            slider("曝光", $model.exposure, -2...2, onEnd: model.refreshPreview)
            slider("對比", $model.contrast, 0.5...1.5, onEnd: model.refreshPreview)
            slider("飽和度", $model.saturation, 0...2, onEnd: model.refreshPreview)
            slider("色溫", $model.warmth, -1...1, onEnd: model.refreshPreview)
            slider("銳利度", $model.sharpness, 0...2, onEnd: model.refreshPreview)
            Divider()
            HStack {
                Button { model.quarterTurns += 3; model.refreshPreview() } label: { Label("向左轉", systemImage: "rotate.left") }
                Button { model.quarterTurns += 1; model.refreshPreview() } label: { Label("向右轉", systemImage: "rotate.right") }
            }
            Button { model.flipH.toggle(); model.refreshPreview() } label: { Label("水平翻轉", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            slider("尺寸", $model.scalePercent, 10...100, format: "%.0f%%", onEnd: {})
            let s = model.imageSize
            Text("輸出：\(Int(s.width * model.scalePercent / 100)) × \(Int(s.height * model.scalePercent / 100))")
                .font(.caption).foregroundStyle(.secondary)
            Button("重設") {
                model.exposure = 0; model.contrast = 1; model.saturation = 1; model.warmth = 0; model.sharpness = 0
                model.quarterTurns = 0; model.flipH = false; model.scalePercent = 100; model.refreshPreview()
            }
        }
    }
}

struct AnnotateControls: View {
    @ObservedObject var model: ImageEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                ForEach(AnnotationTool.allCases) { t in
                    Button { model.tool = t } label: {
                        VStack(spacing: 3) { Image(systemName: t.symbol).font(.system(size: 16)); Text(t.label).font(.caption) }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.tool == t ? WheelView.accent.opacity(0.25) : Color.secondary.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
            }
            ColorPicker("顏色", selection: $model.color)
            HStack(spacing: 6) {
                ForEach([Color.red, .orange, .yellow, .green, .blue, .purple, .black, .white], id: \.self) { c in
                    Circle().fill(c).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5)))
                        .onTapGesture { model.color = c }
                }
            }
            slider("粗細", $model.lineWidth, 1...30, format: "%.0f", onEnd: {})
            if model.tool == .text {
                TextField("文字內容", text: $model.pendingText)
                Text("在圖片上點一下放置文字").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { if !model.annotations.isEmpty { model.annotations.removeLast() } } label: { Label("復原", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                Button("全部清除") { model.annotations.removeAll() }
            }
        }
    }
}

struct CropControls: View {
    @ObservedObject var model: ImageEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拖曳框線或四角調整範圍，拖曳框內可移動。").font(.callout).foregroundStyle(.secondary)
            Picker("比例", selection: Binding(get: { model.aspect ?? 0 }, set: { v in
                model.aspect = v == 0 ? nil : v
                applyAspect()
            })) {
                Text("自由").tag(0.0)
                Text("1:1").tag(1.0)
                Text("4:3").tag(4.0 / 3)
                Text("3:2").tag(3.0 / 2)
                Text("16:9").tag(16.0 / 9)
                Text("9:16").tag(9.0 / 16)
                Text("原始").tag(model.imageSize.width / model.imageSize.height)
            }
            Text("\(Int(model.crop.width)) × \(Int(model.crop.height)) px").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button("重設") { model.aspect = nil; model.crop = CGRect(origin: .zero, size: model.imageSize) }
        }
    }

    private func applyAspect() {
        guard let a = model.aspect else { return }
        let s = model.imageSize
        var w = s.width, h = w / a
        if h > s.height { h = s.height; w = h * a }
        model.crop = CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }
}

struct RedactControls: View {
    @ObservedObject var model: ImageEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在圖片上拖曳框選要遮蔽的區域。").font(.callout).foregroundStyle(.secondary)
            Picker("樣式", selection: $model.redactStyle) { ForEach(RedactStyle.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Button { model.autoDetectRedactions() } label: { Label("自動偵測臉孔與文字", systemImage: "wand.and.stars") }
            HStack {
                Button { if !model.redactions.isEmpty { model.redactions.removeLast() } } label: { Label("復原", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                Button("全部清除") { model.redactions.removeAll() }
            }
            Text("\(model.redactions.count) 個區域").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BackgroundControls: View {
    @ObservedObject var model: ImageEditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("背景").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 8) {
                ForEach(Backdrop.all) { b in
                    swatch(b)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.backdrop == b.id ? WheelView.accent : .secondary.opacity(0.3), lineWidth: model.backdrop == b.id ? 3 : 1))
                        .onTapGesture { model.backdrop = b.id; model.refreshPreview() }
                }
            }
            slider("留白", $model.padding, 0...0.4, format: "%.2f", onEnd: model.refreshPreview)
            slider("圓角", $model.corner, 0...0.15, format: "%.2f", onEnd: model.refreshPreview)
            Toggle("陰影", isOn: $model.shadow).onChange(of: model.shadow) { _, _ in model.refreshPreview() }
            Toggle("先自動去背（主體）", isOn: $model.removeSubjectBackground)
                .onChange(of: model.removeSubjectBackground) { _, _ in model.toggleCutout() }
        }
    }

    @ViewBuilder
    private func swatch(_ b: Backdrop) -> some View {
        if b.colors.isEmpty {
            // checkerboard = transparent
            Canvas { ctx, size in
                let s: CGFloat = 8
                for y in stride(from: 0, to: size.height, by: s) {
                    for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.3)))
                    }
                }
            }
        } else if b.colors.count == 1 {
            Color(nsColor: b.colors[0])
        } else {
            LinearGradient(colors: b.colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Canvas (image + interactive overlay)

struct EditorCanvas: View {
    @ObservedObject var model: ImageEditorModel
    @State private var draft: Annotation?
    @State private var draftRect: CGRect?
    @State private var cropDrag: (handle: Int, start: CGRect)?

    var body: some View {
        GeometryReader { geo in
            let img = model.preview
            let size = CGSize(width: img.width, height: img.height)
            let fit = fitRect(size, in: geo.size.insetBy(24))
            ZStack(alignment: .topLeading) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .shadow(radius: 6)
                overlay(fit: fit)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(fit: fit))
        }
    }

    private func fitRect(_ size: CGSize, in area: CGSize) -> CGRect {
        let s = min(area.width / size.width, area.height / size.height, 4)
        let w = size.width * s, h = size.height * s
        return CGRect(x: 24 + (area.width - w) / 2, y: 24 + (area.height - h) / 2, width: w, height: h)
    }

    /// view point -> image pixel point
    private func toImage(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        let s = model.imageSize.width / fit.width
        return CGPoint(x: min(max((p.x - fit.minX) * s, 0), model.imageSize.width),
                       y: min(max((p.y - fit.minY) * s, 0), model.imageSize.height))
    }
    private func toView(_ r: CGRect, _ fit: CGRect) -> CGRect {
        let s = fit.width / model.imageSize.width
        return CGRect(x: fit.minX + r.minX * s, y: fit.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    @ViewBuilder
    private func overlay(fit: CGRect) -> some View {
        switch model.mode {
        case .annotate:
            Canvas { ctx, _ in
                let s = fit.width / model.imageSize.width
                ctx.translateBy(x: fit.minX, y: fit.minY)
                ctx.scaleBy(x: s, y: s)
                ctx.withCGContext { cg in
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                    for a in model.annotations + (draft.map { [$0] } ?? []) { ImageEditorModel.stroke(a, in: cg) }
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            .allowsHitTesting(false)
        case .redact:
            ForEach(Array((model.redactions + (draftRect.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                let v = toView(r, fit)
                Rectangle()
                    .fill(Color.black.opacity(model.redactStyle == .black ? 0.85 : 0.45))
                    .overlay(Rectangle().strokeBorder(WheelView.accent, lineWidth: 1.5))
                    .frame(width: v.width, height: v.height)
                    .offset(x: v.minX, y: v.minY)
                    .allowsHitTesting(false)
            }
        case .crop:
            let v = toView(model.crop, fit)
            ZStack(alignment: .topLeading) {
                // Dim outside the crop
                Path { p in
                    p.addRect(fit)
                    p.addRect(v)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(.white, lineWidth: 2)
                    .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                // rule of thirds
                Path { p in
                    for i in 1...2 {
                        let x = v.minX + v.width * CGFloat(i) / 3, y = v.minY + v.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: v.minY)); p.addLine(to: CGPoint(x: x, y: v.maxY))
                        p.move(to: CGPoint(x: v.minX, y: y)); p.addLine(to: CGPoint(x: v.maxX, y: y))
                    }
                }.stroke(.white.opacity(0.5), lineWidth: 0.7)
                ForEach(0..<4) { i in
                    let pt = [CGPoint(x: v.minX, y: v.minY), CGPoint(x: v.maxX, y: v.minY), CGPoint(x: v.minX, y: v.maxY), CGPoint(x: v.maxX, y: v.maxY)][i]
                    Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 2)
                        .offset(x: pt.x - 7, y: pt.y - 7)
                }
            }
            .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private func dragGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let a = toImage(g.startLocation, fit), b = toImage(g.location, fit)
                switch model.mode {
                case .annotate:
                    let scale = model.imageSize.width / fit.width
                    if draft == nil {
                        draft = Annotation(tool: model.tool, points: [a], color: NSColor(model.color),
                                           width: CGFloat(model.lineWidth) * scale, text: model.pendingText)
                    }
                    if model.tool == .pen || model.tool == .highlighter { draft?.points.append(b) }
                    else if model.tool != .text { draft?.points = [a, b] }
                case .redact:
                    draftRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                case .crop:
                    updateCrop(start: a, now: b, fit: fit)
                default: break
                }
            }
            .onEnded { _ in
                if let d = draft { model.annotations.append(d) }
                if let r = draftRect, r.width > 3, r.height > 3 { model.redactions.append(r) }
                draft = nil; draftRect = nil; cropDrag = nil
            }
    }

    /// handle: 0..3 corners (tl, tr, bl, br), 4 = move
    private func updateCrop(start: CGPoint, now: CGPoint, fit: CGRect) {
        if cropDrag == nil {
            let c = model.crop
            let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)]
            let tol = 24 * model.imageSize.width / fit.width
            let handle = corners.firstIndex { hypot($0.x - start.x, $0.y - start.y) < tol } ?? (c.contains(start) ? 4 : 0)
            cropDrag = (handle, c)
        }
        guard let (h, s) = cropDrag else { return }
        let dx = now.x - start.x, dy = now.y - start.y
        let size = model.imageSize
        var r = s
        switch h {
        case 4:
            r.origin.x = min(max(s.minX + dx, 0), size.width - s.width)
            r.origin.y = min(max(s.minY + dy, 0), size.height - s.height)
        default:
            var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
            if h == 0 || h == 2 { minX = min(max(0, s.minX + dx), maxX - 20) } else { maxX = max(min(size.width, s.maxX + dx), minX + 20) }
            if h == 0 || h == 1 { minY = min(max(0, s.minY + dy), maxY - 20) } else { maxY = max(min(size.height, s.maxY + dy), minY + 20) }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if let a = model.aspect {
                // keep aspect by adjusting height from the anchored side
                let h2 = r.width / a
                if h == 0 || h == 1 { r.origin.y = r.maxY - h2 }
                r.size.height = h2
                if r.minY < 0 || r.maxY > size.height { return }
            }
        }
        model.crop = r
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(1, width - d * 2), height: max(1, height - d * 2)) }
}
