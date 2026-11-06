import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import PDFKit

enum ImageEngine {
    // MARK: Loading

    /// Loads the image with EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        }
        // Fallback for formats ImageIO cannot read (e.g. SVG) – go through NSImage.
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: ns.size)
            let scale: CGFloat = 2
            let px = CGSize(width: max(1, ns.size.width * scale), height: max(1, ns.size.height * scale))
            if let ctx = bitmapContext(width: Int(px.width), height: Int(px.height)) {
                let g = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = g
                rect = CGRect(origin: .zero, size: px)
                ns.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                if let img = ctx.makeImage() { return img }
            }
        }
        throw MarshmallowError("無法讀取圖片 \(url.lastPathComponent)")
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: Saving

    static func utType(forExt ext: String) -> UTType? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "avif": return UTType("public.avif")
        case "tiff", "tif": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "ico": return .ico
        case "icns": return .icns
        case "jp2": return UTType("public.jpeg-2000")
        default: return UTType(filenameExtension: ext)
        }
    }

    /// Writes `image` to `url` with the format implied by the extension.
    static func save(_ image: CGImage, to url: URL, quality: Double? = nil, metadata: [CFString: Any]? = nil) throws {
        let ext = url.pathExtension.lowercased()
        let q = quality ?? Settings.shared.quality
        var img = image

        switch ext {
        case "webp":
            try saveWebP(img, to: url, quality: q, metadata: metadata)
            return
        case "pdf":
            try savePDF([img], to: url)
            return
        case "jpg", "jpeg", "bmp":
            if hasAlpha(img) { img = flatten(img, background: .white) }
        case "ico":
            img = fit(img, maxSide: 256)
        case "icns":
            img = squareCanvas(fit(img, maxSide: 1024), side: 1024)
        default: break
        }

        guard let type = utType(forExt: ext),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw MarshmallowError("不支援輸出 \(ext.uppercased())")
        }
        var props: [CFString: Any] = metadata ?? [:]
        if ["jpg", "jpeg", "heic", "avif", "jp2", "webp"].contains(ext) {
            props[kCGImageDestinationLossyCompressionQuality] = q
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MarshmallowError("寫入 \(ext.uppercased()) 失敗") }
    }

    private static func saveWebP(_ img: CGImage, to url: URL, quality: Double, metadata: [CFString: Any]?) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try save(img, to: tmp, metadata: metadata)
        // Try system ImageIO first (newer macOS versions may support WebP writing).
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "org.webmproject.webp" as CFString, 1, nil) {
            var props = metadata ?? [:]
            props[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            if CGImageDestinationFinalize(dest) { return }
        }
        let sema = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                if let cwebp = ToolLocator.cwebp {
                    try await Shell.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", metadata == nil ? "none" : "exif", tmp.path, "-o", url.path])
                } else if ToolLocator.hasFFmpeg {
                    try await Shell.ffmpeg(["-i", tmp.path, "-c:v", "libwebp", "-quality", String(Int(quality * 100)), url.path])
                } else {
                    throw MarshmallowError("輸出 WebP 需要 cwebp 或 ffmpeg：brew install webp")
                }
            } catch { failure = error }
            sema.signal()
        }
        sema.wait()
        if let failure { throw failure }
    }

    static func savePDF(_ images: [CGImage], to url: URL) throws {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            if let page = PDFPage(image: ns) { doc.insert(page, at: i) }
        }
        guard doc.write(to: url) else { throw MarshmallowError("寫入 PDF 失敗") }
    }

    // MARK: Capture info (date & camera, never location)

    /// EXIF keys that describe *when* and *with what* a photo was taken.
    /// Location (GPS), IPTC (place names), maker notes and serial numbers are never copied.
    private static let keptExif: [CFString] = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
        kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized,
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifFlash,
        kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifExposureProgram, kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifWhiteBalance, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
    ]
    private static let keptTIFF: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime]

    /// Properties to carry over from `url` when converting, per the user's setting.
    /// Orientation is not copied: pixels are already rotated upright by `load`.
    static func captureInfo(from url: URL) -> [CFString: Any]? {
        guard Settings.shared.keepCaptureInfo,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var out: [CFString: Any] = [:]
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let kept = exif.filter { keptExif.contains($0.key) }
            if !kept.isEmpty { out[kCGImagePropertyExifDictionary] = kept }
        }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var kept = tiff.filter { keptTIFF.contains($0.key) }
            kept[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = kept
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    // MARK: Conversions

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = OutputNamer.url(for: url, ext: ext)
        // Preserve animation for GIF -> WebP via ffmpeg when possible.
        if url.pathExtension.lowercased() == "gif", ext == "webp", ToolLocator.hasFFmpeg, frameCount(url) > 1 {
            let sema = DispatchSemaphore(value: 0); var err: Error?
            Task.detached {
                do { try await Shell.ffmpeg(["-i", url.path, "-c:v", "libwebp_anim", "-loop", "0", "-quality", "80", out.path]) } catch { err = error }
                sema.signal()
            }
            sema.wait()
            if let err { throw err }
            return out
        }
        try save(try load(url), to: out, metadata: captureInfo(from: url))
        return out
    }

    static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    // MARK: Geometry helpers

    static func flatten(_ img: CGImage, background: NSColor) -> CGImage {
        guard let ctx = bitmapContext(width: img.width, height: img.height) else { return img }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func scaled(_ img: CGImage, factor: Double) -> CGImage {
        let w = max(1, Int(Double(img.width) * factor)), h = max(1, Int(Double(img.height) * factor))
        guard let ctx = bitmapContext(width: w, height: h) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func fit(_ img: CGImage, maxSide: Int) -> CGImage {
        let m = max(img.width, img.height)
        return m > maxSide ? scaled(img, factor: Double(maxSide) / Double(m)) : img
    }

    static func squareCanvas(_ img: CGImage, side: Int) -> CGImage {
        guard let ctx = bitmapContext(width: side, height: side) else { return img }
        ctx.interpolationQuality = .high
        let s = min(Double(side) / Double(img.width), Double(side) / Double(img.height))
        let w = Double(img.width) * s, h = Double(img.height) * s
        ctx.draw(img, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func rotated90(_ img: CGImage) -> CGImage {
        let w = img.height, h = img.width
        guard let ctx = bitmapContext(width: w, height: h) else { return img }
        // Clockwise rotation.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func flippedHorizontally(_ img: CGImage) -> CGImage {
        guard let ctx = bitmapContext(width: img.width, height: img.height) else { return img }
        ctx.translateBy(x: CGFloat(img.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    /// Trims uniform / transparent borders. Falls back to a centered square crop.
    static func autoCrop(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = bitmapContext(width: w, height: h), let data = ctx.data else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let o = y * bpr + x * 4
            return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]), Int(p[o + 3]))
        }
        let ref = px(0, 0)
        func differs(_ x: Int, _ y: Int) -> Bool {
            let c = px(x, y)
            if ref.3 < 10 { return c.3 > 10 }
            return abs(c.0 - ref.0) + abs(c.1 - ref.1) + abs(c.2 - ref.2) + abs(c.3 - ref.3) > 40
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        let step = max(1, min(w, h) / 1500)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if differs(x, y) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                x += step
            }
            y += step
        }
        if maxX >= minX, maxY >= minY {
            let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let trimmed = rect.width < CGFloat(w) - 2 || rect.height < CGFloat(h) - 2
            // bitmap memory is top-down in our context, which matches CGImage cropping coords.
            if trimmed, let c = ctx.makeImage()?.cropping(to: rect) { return c }
        }
        let side = min(w, h)
        return img.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)) ?? img
    }

    // MARK: Tools

    static let ci = CIContext()

    static func removeBackground(_ img: CGImage) throws -> CGImage {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([req])
        guard let result = req.results?.first else { throw MarshmallowError("找不到前景主體") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let out = ci.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw MarshmallowError("去背失敗")
        }
        return out
    }

    /// Pixelates faces and text.
    static func redact(_ img: CGImage) throws -> CGImage {
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([faces, text])
        var boxes: [CGRect] = (faces.results ?? []).map { $0.boundingBox }
        boxes += (text.results ?? []).map { $0.boundingBox }
        if boxes.isEmpty { throw MarshmallowError("沒有偵測到臉孔或文字") }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let input = CIImage(cgImage: img)
        let pix = CIFilter.pixellate()
        pix.inputImage = input.clampedToExtent()
        pix.scale = Float(max(12, min(W, H) / 40))
        guard let pixelated = pix.outputImage?.cropped(to: input.extent) else { return img }
        var maskImage = CIImage(color: .clear).cropped(to: input.extent)
        for b in boxes {
            let r = CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H).insetBy(dx: -6, dy: -6)
            maskImage = CIImage(color: .white).cropped(to: r).composited(over: maskImage)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelated
        blend.backgroundImage = input
        blend.maskImage = maskImage
        guard let out = blend.outputImage, let cg = ci.createCGImage(out, from: input.extent) else { return img }
        return cg
    }

    static func grayscale(_ img: CGImage) -> CGImage {
        let f = CIFilter.photoEffectMono()
        f.inputImage = CIImage(cgImage: img)
        guard let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent) else { return img }
        return cg
    }

    /// Strips metadata, losslessly when ImageIO allows it.
    static func stripMetadata(_ url: URL) throws -> URL {
        let out = OutputNamer.url(for: url, ext: url.pathExtension, suffix: "no metadata")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw MarshmallowError("無法讀取圖片")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            let meta = CGImageMetadataCreateMutable()
            if let orientation = props?[kCGImagePropertyOrientation] {
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation, orientation as CFTypeRef)
            }
            let opts: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var err: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) { return out }
        }
        // Fallback: re-encode pixels only.
        try? FileManager.default.removeItem(at: out)
        try save(try load(url), to: out, quality: 0.95)
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        var img = fit(try load(url), maxSide: 3000)
        var outExt = ext
        var q = min(Settings.shared.quality, 0.65)
        switch ext {
        case "jpg", "jpeg", "heic", "avif", "webp": break
        case "png":
            if !hasAlpha(img) || !imageUsesAlpha(img) { outExt = "jpg"; img = flatten(img, background: .white) }
            else { outExt = "png" }
        default:
            outExt = hasAlpha(img) ? "png" : "jpg"
        }
        if outExt == "png" { q = 1 }
        let out = OutputNamer.url(for: url, ext: outExt, suffix: "compressed")
        try save(img, to: out, quality: q, metadata: captureInfo(from: url))
        return out
    }

    /// True when at least one pixel is not fully opaque.
    static func imageUsesAlpha(_ img: CGImage) -> Bool {
        let small = fit(img, maxSide: 256)
        guard let ctx = bitmapContext(width: small.width, height: small.height), let data = ctx.data else { return true }
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * small.height)
        for y in 0..<small.height {
            for x in 0..<small.width where p[y * ctx.bytesPerRow + x * 4 + 3] < 250 { return true }
        }
        return false
    }

    /// Applies a pixel transform and writes a sibling file.
    static func transform(_ url: URL, suffix: String, forceExt: String? = nil, _ body: (CGImage) throws -> CGImage) throws -> URL {
        var ext = forceExt ?? url.pathExtension.lowercased()
        if utType(forExt: ext) == nil && ext != "webp" { ext = "png" }
        if ["svg", "gif", "ico", "icns"].contains(ext) && forceExt == nil { ext = "png" }
        let out = OutputNamer.url(for: url, ext: ext, suffix: suffix)
        try save(try body(try load(url)), to: out, quality: 0.92, metadata: suffix == "redacted" ? nil : captureInfo(from: url))
        return out
    }
}
