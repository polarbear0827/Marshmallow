import AppKit

/// Minimal writers for zip-based document formats (DOCX with images, XLSX, EPUB).
enum OfficeWriter {
    // MARK: Zip packaging

    /// Writes `files` (relative path -> data) into a zip at `out`.
    /// `stored` entries are added first and uncompressed (EPUB's `mimetype`).
    static func package(_ files: [(String, Data)], to out: URL, stored: [String] = []) async throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("mm-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        for (path, data) in files {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try? FileManager.default.removeItem(at: out)
        if !stored.isEmpty {
            try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", out.path] + stored, cwd: stage)
        }
        let rest = files.map(\.0).filter { !stored.contains($0) }
        try await Shell.run("/usr/bin/zip", ["-X", "-9", "-q", out.path] + rest, cwd: stage)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: DOCX with images

    /// One image per page, scaled to fit the printable area of a Letter page.
    static func docx(images: [CGImage], to out: URL) async throws {
        var files: [(String, Data)] = []
        var rels = ""
        var body = ""
        let emuPerInch = 914_400.0
        let maxW = 6.5 * emuPerInch, maxH = 9.0 * emuPerInch
        for (i, img) in images.enumerated() {
            let n = i + 1
            let rep = NSBitmapImageRep(cgImage: img)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            files.append(("word/media/image\(n).png", png))
            rels += #"<Relationship Id="rIdImg\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#(n).png"/>"#
            // 96 dpi nominal size, shrunk to fit.
            var w = Double(img.width) / 96 * emuPerInch, h = Double(img.height) / 96 * emuPerInch
            let s = min(1, maxW / w, maxH / h)
            w *= s; h *= s
            let cx = Int(w), cy = Int(h)
            if i > 0 { body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"# }
            body += """
            <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(n)" name="Picture \(n)"/>\
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).png"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="rIdImg\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        files += [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            </Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """.utf8)),
            ("word/_rels/document.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """.utf8)),
            ("word/document.xml", Data(document.utf8)),
        ]
        try await package(files, to: out)
    }
}
