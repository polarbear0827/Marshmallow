import AppKit
import PDFKit

/// Text documents (DOCX/RTF/ODT/HTML/TXT/MD) and PDF operations.
enum DocumentEngine {
    // MARK: Reading

    @MainActor
    static func attributedString(from url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if FileKind.of(url) == .pdf {
            return try pdfAttributedString(url)
        }
        if ext == "md" || ext == "markdown" {
            let md = try String(contentsOf: url, encoding: .utf8)
            return markdownToAttributed(md)
        }
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if ["txt", "text"].contains(ext) {
            opts[.documentType] = NSAttributedString.DocumentType.plain
            opts[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let s = try NSAttributedString(url: url, options: opts, documentAttributes: nil)
        return plainDefaults(s)
    }

    /// Gives unstyled text a readable default font.
    static func plainDefaults(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            if value == nil { m.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        return m
    }

    @MainActor
    static func pdfAttributedString(_ url: URL) throws -> NSAttributedString {
        guard let doc = PDFDocument(url: url) else { throw MarshmallowError("無法開啟 PDF") }
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let a = doc.page(at: i)?.attributedString { out.append(a) }
            if i < doc.pageCount - 1 { out.append(NSAttributedString(string: "\n\n")) }
        }
        return plainDefaults(out)
    }

    /// Very small Markdown renderer: headings, bold/italic/code/links via Foundation, lists kept as text.
    static func markdownToAttributed(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        for line in md.components(separatedBy: "\n") {
            var text = line
            var font = body
            var level = 0
            while text.hasPrefix("#") { level += 1; text.removeFirst() }
            if level > 0 {
                text = text.trimmingCharacters(in: .whitespaces)
                font = NSFont.boldSystemFont(ofSize: max(14, 26 - CGFloat(level) * 3))
            }
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let inline = (try? NSMutableAttributedString(AttributedString(markdown: text, options: opts))) ?? NSMutableAttributedString(string: text)
            let full = NSRange(location: 0, length: inline.length)
            inline.addAttribute(.font, value: font, range: full)
            // Map Foundation inline intents onto fonts.
            inline.enumerateAttribute(NSAttributedString.Key("NSInlinePresentationIntent"), in: full) { v, r, _ in
                guard let raw = v as? UInt else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    inline.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: r)
                } else if !traits.isEmpty {
                    let d = font.fontDescriptor.withSymbolicTraits(traits)
                    inline.addAttribute(.font, value: NSFont(descriptor: d, size: font.pointSize) ?? font, range: r)
                }
            }
            out.append(inline)
            out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }
        return out
    }

    // MARK: Writing

    @MainActor
    static func convert(_ url: URL, to ext: String) throws -> URL {
        if FileKind.of(url) == .pdf, ["png", "jpg", "heic", "tiff"].contains(ext) {
            return try pdfToImages(url, ext: ext)
        }
        let s = try attributedString(from: url)
        let out = OutputNamer.url(for: url, ext: ext)
        try write(s, to: out)
        return out
    }

    @MainActor
    static func write(_ s: NSAttributedString, to out: URL) throws {
        let range = NSRange(location: 0, length: s.length)
        switch out.pathExtension.lowercased() {
        case "pdf":
            try renderPDF(s, to: out)
        case "txt":
            try s.string.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try s.string.write(to: out, atomically: true, encoding: .utf8)
        case "png", "jpg":
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try renderPDF(s, to: tmp)
            guard let page = PDFDocument(url: tmp)?.page(at: 0) else { throw MarshmallowError("轉換失敗") }
            try ImageEngine.save(render(page, scale: 2), to: out)
        default:
            let type: NSAttributedString.DocumentType
            switch out.pathExtension.lowercased() {
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            case "rtf": type = .rtf
            case "html", "htm": type = .html
            case "rtfd": type = .rtfd
            default: throw MarshmallowError("不支援輸出 \(out.pathExtension.uppercased())")
            }
            let data = try s.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
    }

    /// Paginates an attributed string onto US-Letter pages.
    @MainActor
    static func renderPDF(_ s: NSAttributedString, to out: URL) throws {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 60
        let content = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: content)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            layout.ensureLayout(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 2000

        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw MarshmallowError("無法建立 PDF") }
        for c in containers {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let range = layout.glyphRange(for: c)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: PDF

    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = ImageEngine.bitmapContext(width: max(w, 1), height: max(h, 1))!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
    }

    static func pdfToImages(_ url: URL, ext: String) throws -> URL {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw MarshmallowError("無法開啟 PDF") }
        if doc.pageCount == 1 {
            let out = OutputNamer.url(for: url, ext: ext)
            try ImageEngine.save(render(doc.page(at: 0)!, scale: 2), to: out)
            return out
        }
        let folder = OutputNamer.folder(for: url, suffix: ext.uppercased())
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            let out = folder.appendingPathComponent("\(base)-\(i + 1)").appendingPathExtension(ext)
            try ImageEngine.save(render(doc.page(at: i)!, scale: 2), to: out)
        }
        return folder
    }

    enum PDFTool { case compress, metadata, rotate, split, reverse, extractText, grayscale }

    static func apply(_ tool: PDFTool, to url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw MarshmallowError("無法開啟 PDF") }
        switch tool {
        case .compress:
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "compressed")
            let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            guard ok else { throw MarshmallowError("壓縮 PDF 失敗") }
            return out
        case .metadata:
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "no metadata")
            doc.documentAttributes = [
                PDFDocumentAttribute.titleAttribute: "", PDFDocumentAttribute.authorAttribute: "",
                PDFDocumentAttribute.subjectAttribute: "", PDFDocumentAttribute.creatorAttribute: "",
                PDFDocumentAttribute.producerAttribute: "", PDFDocumentAttribute.keywordsAttribute: [String](),
            ]
            guard doc.write(to: out) else { throw MarshmallowError("寫入 PDF 失敗") }
            return out
        case .rotate:
            for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "rotated")
            guard doc.write(to: out) else { throw MarshmallowError("寫入 PDF 失敗") }
            return out
        case .reverse:
            let rev = PDFDocument()
            for i in 0..<doc.pageCount { if let p = doc.page(at: doc.pageCount - 1 - i) { rev.insert(p, at: i) } }
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "reversed")
            guard rev.write(to: out) else { throw MarshmallowError("寫入 PDF 失敗") }
            return out
        case .split:
            let folder = OutputNamer.folder(for: url, suffix: "pages")
            let base = url.deletingPathExtension().lastPathComponent
            for i in 0..<doc.pageCount {
                let single = PDFDocument()
                if let p = doc.page(at: i) { single.insert(p, at: 0) }
                single.write(to: folder.appendingPathComponent("\(base)-\(i + 1).pdf"))
            }
            return folder
        case .extractText:
            let out = OutputNamer.url(for: url, ext: "txt")
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        case .grayscale:
            let out = OutputNamer.url(for: url, ext: "pdf", suffix: "grayscale")
            let gray = PDFDocument()
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                let img = ImageEngine.grayscale(render(p, scale: 2))
                let ns = NSImage(cgImage: img, size: p.bounds(for: .mediaBox).size)
                if let np = PDFPage(image: ns) { gray.insert(np, at: gray.pageCount) }
            }
            guard gray.write(to: out) else { throw MarshmallowError("寫入 PDF 失敗") }
            return out
        }
    }

    /// Merges images and PDFs (in the given order) into one PDF.
    static func merge(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            if FileKind.of(url) == .pdf, let src = PDFDocument(url: url) {
                for i in 0..<src.pageCount { if let p = src.page(at: i) { doc.insert(p, at: doc.pageCount) } }
            } else if FileKind.of(url) == .image {
                let img = try ImageEngine.load(url)
                let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                if let p = PDFPage(image: ns) { doc.insert(p, at: doc.pageCount) }
            }
        }
        guard doc.pageCount > 0, let first = urls.first else { throw MarshmallowError("沒有可合併的頁面") }
        let dir = Settings.shared.outputDirectory(for: first)
        let out = OutputNamer.unique(dir.appendingPathComponent("Merged.pdf"))
        guard doc.write(to: out) else { throw MarshmallowError("寫入 PDF 失敗") }
        return out
    }
}
