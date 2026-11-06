import AppKit

/// Spreadsheets, presentations and e-books.
enum OfficeEngine {
    // MARK: - Spreadsheet model

    typealias Table = [[String]]

    static func readTable(_ url: URL) async throws -> Table {
        switch url.pathExtension.lowercased() {
        case "csv": return parseDelimited(try readText(url), separator: ",")
        case "tsv", "tab": return parseDelimited(try readText(url), separator: "\t")
        case "xlsx": return try await readXLSX(url)
        default:
            // xls / numbers / ods: let Numbers turn it into xlsx first.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await IWork.export(url, with: .numbers, ext: "xlsx", to: tmp)
            return try await readXLSX(tmp)
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 4180-ish parser (quotes, escaped quotes, newlines inside quotes).
    static func parseDelimited(_ text: String, separator: Character) -> Table {
        var rows: Table = [], row: [String] = [], field = ""
        var inQuotes = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func writeDelimited(_ t: Table, separator: String) -> String {
        t.map { row in
            row.map { f in
                f.contains(separator) || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    // MARK: XLSX read

    private static func unzipEntry(_ zip: URL, _ entry: String) async throws -> Data? {
        let out = try? await Shell.run("/usr/bin/unzip", ["-p", zip.path, entry])
        guard let out, !out.isEmpty else { return nil }
        return Data(out.utf8)
    }

    static func readXLSX(_ url: URL) async throws -> Table {
        let shared = try await unzipEntry(url, "xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        guard let sheet = try await unzipEntry(url, "xl/worksheets/sheet1.xml") else {
            throw MarshmallowError("無法讀取 XLSX 工作表")
        }
        return SheetParser.parse(sheet, shared: shared)
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []; var current = ""; var inT = false
        static func parse(_ d: Data) -> [String] {
            let p = SharedStringsParser(); let x = XMLParser(data: d); x.delegate = p; x.parse(); return p.strings
        }
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { current = "" }; if e == "t" { inT = true }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if inT { current += s } }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false }; if e == "si" { strings.append(current) }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        var shared: [String] = []
        var cells: [(Int, Int, String)] = []
        var ref = "", type = "", value = "", inV = false
        static func parse(_ d: Data, shared: [String]) -> Table {
            let p = SheetParser(); p.shared = shared
            let x = XMLParser(data: d); x.delegate = p; x.parse()
            let maxR = p.cells.map(\.0).max() ?? -1, maxC = p.cells.map(\.1).max() ?? -1
            guard maxR >= 0 else { return [] }
            var t = Table(repeating: Array(repeating: "", count: maxC + 1), count: maxR + 1)
            for (r, c, v) in p.cells { t[r][c] = v }
            return t
        }
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if e == "c" { ref = a["r"] ?? ""; type = a["t"] ?? ""; value = "" }
            if e == "v" || e == "t" { inV = true }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if inV { value += s } }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "v" || e == "t" { inV = false }
            if e == "c" {
                var v = value
                if type == "s", let i = Int(value), shared.indices.contains(i) { v = shared[i] }
                if type == "b" { v = value == "1" ? "TRUE" : "FALSE" }
                if let (r, c) = Self.position(ref) { cells.append((r, c, v)) }
            }
        }
        static func position(_ ref: String) -> (Int, Int)? {
            var col = 0, digits = ""
            for ch in ref {
                if ch.isLetter, let a = ch.uppercased().unicodeScalars.first?.value { col = col * 26 + Int(a) - 64 }
                else { digits.append(ch) }
            }
            guard let row = Int(digits), col > 0 else { return nil }
            return (row - 1, col - 1)
        }
    }

    // MARK: XLSX write

    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func writeXLSX(_ t: Table, to out: URL) async throws {
        var rows = ""
        for (r, row) in t.enumerated() {
            rows += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() where !v.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                if Double(v) != nil, !v.hasPrefix("0") || v == "0" || v.hasPrefix("0.") {
                    rows += "<c r=\"\(ref)\"><v>\(v)</v></c>"
                } else {
                    rows += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OfficeWriter.xmlEscape(v))</t></is></c>"
                }
            }
            rows += "</row>"
        }
        let files: [(String, Data)] = [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            </Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
            </Relationships>
            """.utf8)),
            ("xl/worksheets/sheet1.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
            """.utf8)),
        ]
        try await OfficeWriter.package(files, to: out)
    }

    // MARK: Other table outputs

    static func html(_ t: Table, title: String) -> String {
        let head = t.first.map { "<thead><tr>" + $0.map { "<th>\(OfficeWriter.xmlEscape($0))</th>" }.joined() + "</tr></thead>" } ?? ""
        let body = t.dropFirst().map { "<tr>" + $0.map { "<td>\(OfficeWriter.xmlEscape($0))</td>" }.joined() + "</tr>" }.joined(separator: "\n")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(OfficeWriter.xmlEscape(title))</title>
        <style>body{font-family:-apple-system,Helvetica;font-size:14px}table{border-collapse:collapse}
        th,td{border:1px solid #bbb;padding:3px 6px;text-align:left}th{background:#f2f2f2}</style></head>
        <body><table>\(head)<tbody>\(body)</tbody></table></body></html>
        """
    }

    static func markdown(_ t: Table) -> String {
        guard let header = t.first else { return "" }
        let w = t.map(\.count).max() ?? header.count
        func line(_ r: [String]) -> String {
            "| " + (0..<w).map { i in (i < r.count ? r[i] : "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + String(repeating: " --- |", count: w)] + t.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }

    static func json(_ t: Table) throws -> Data {
        guard let header = t.first else { return Data("[]".utf8) }
        let objects = t.dropFirst().map { row -> [String: String] in
            var o: [String: String] = [:]
            for (i, k) in header.enumerated() { o[k.isEmpty ? "column\(i + 1)" : k] = i < row.count ? row[i] : "" }
            return o
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func convertSpreadsheet(_ url: URL, to ext: String) async throws -> URL {
        let out = OutputNamer.url(for: url, ext: ext)
        let src = url.pathExtension.lowercased()
        // Formats Numbers produces with full fidelity.
        if IWork.App.numbers.isInstalled, ["pdf", "numbers"].contains(ext) || (["xls", "numbers", "ods"].contains(src) && ["xlsx", "csv"].contains(ext)) {
            try await IWork.export(url, with: .numbers, ext: ext, to: out)
            return out
        }
        let t = try await readTable(url)
        switch ext {
        case "xlsx": try await writeXLSX(t, to: out)
        case "csv": try writeDelimited(t, separator: ",").write(to: out, atomically: true, encoding: .utf8)
        case "tsv": try writeDelimited(t, separator: "\t").write(to: out, atomically: true, encoding: .utf8)
        case "json": try json(t).write(to: out)
        case "md": try markdown(t).write(to: out, atomically: true, encoding: .utf8)
        case "html": try html(t, title: url.lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            let html = html(t, title: url.lastPathComponent)
            try await MainActor.run {
                let s = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                try DocumentEngine.renderPDF(s, to: out)
            }
        case "numbers": throw MarshmallowError("需要 Numbers")
        default: throw MarshmallowError("不支援輸出 \(ext.uppercased())")
        }
        return out
    }

    // MARK: - Documents (Pages when available, native otherwise)

    static func convertDocument(_ url: URL, to ext: String) async throws -> URL {
        let src = url.pathExtension.lowercased()
        let kind = FileKind.of(url)
        if ext == "pptx" || ext == "key" { return try await deck(from: url, ext: ext) }

        // Pages gives the best fidelity for Word-family documents.
        let pagesInputs: Set<String> = ["docx", "doc", "pages", "rtf", "txt"]
        if IWork.App.pages.isInstalled, pagesInputs.contains(src), IWork.exportFormat(.pages, ext: ext) != nil {
            let out = OutputNamer.url(for: url, ext: ext)
            try await IWork.export(url, with: .pages, ext: ext, to: out)
            return out
        }
        if src == "pages" {
            // Pages not installed: only Pages can read .pages; produce via Pages-docx export.
            throw MarshmallowError("需要 Pages 才能讀取 .pages 檔")
        }

        // PDF -> images keeps its own path.
        if kind == .pdf, ["png", "jpg", "heic", "tiff"].contains(ext) {
            return try await MainActor.run { try DocumentEngine.convert(url, to: ext) }
        }

        // Read into an attributed string natively.
        let s: NSAttributedString = kind == .ebook
            ? try await readEPUB(url)
            : try await MainActor.run { try DocumentEngine.attributedString(from: url) }
        let out = OutputNamer.url(for: url, ext: ext)
        switch ext {
        case "epub":
            try await writeEPUB(s, title: url.deletingPathExtension().lastPathComponent, to: out)
        case "pages":
            // Go through DOCX, then let Pages save it as .pages.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await MainActor.run { try DocumentEngine.write(s, to: tmp) }
            try await IWork.export(tmp, with: .pages, ext: "pages", to: out)
        default:
            try await MainActor.run { try DocumentEngine.write(s, to: out) }
        }
        return out
    }

    // MARK: - Presentations (Keynote)

    static func convertPresentation(_ url: URL, to ext: String) async throws -> URL {
        if ["png", "jpg", "tiff"].contains(ext) {
            return try await IWork.slideImages(url, ext: ext)
        }
        let target = ext == "mp4" ? "m4v" : ext
        let out = OutputNamer.url(for: url, ext: target)
        try await IWork.export(url, with: .keynote, ext: target, to: out)
        return out
    }

    /// Images (or PDF pages) -> one slide each.
    static func deck(from url: URL, ext: String) async throws -> URL {
        var images: [URL] = [url]
        var cleanup: URL?
        if FileKind.of(url) == .pdf {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-deck-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cleanup = dir
            guard let doc = PDFKitBridge.document(url) else { throw MarshmallowError("無法開啟 PDF") }
            images = try (0..<doc.pageCount).map { i in
                let u = dir.appendingPathComponent(String(format: "page-%03d.png", i + 1))
                try ImageEngine.save(DocumentEngine.render(doc.page(at: i)!, scale: 2), to: u)
                return u
            }
        } else if ["webp", "avif", "heic", "svg", "bmp", "ico"].contains(url.pathExtension.lowercased()) {
            // Keynote prefers common formats.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-deck-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            cleanup = dir
            let u = dir.appendingPathComponent("image.png")
            try ImageEngine.save(try ImageEngine.load(url), to: u)
            images = [u]
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        let out = OutputNamer.url(for: url, ext: ext)
        try await IWork.deck(fromImages: images, ext: ext, to: out)
        return out
    }

    // MARK: - EPUB

    /// Reads an EPUB's spine into one attributed string.
    @MainActor
    static func readEPUB(_ url: URL) async throws -> NSAttributedString {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Shell.run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", dir.path])
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = (try? Regex(#"full-path="([^"]+)""#).firstMatch(in: container))?.output[1].substring else { throw MarshmallowError("EPUB 格式錯誤") }
        let opfURL = dir.appendingPathComponent(String(opfPath))
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        for m in opf.matches(of: try Regex(#"<item\b[^>]*>"#)) {
            let tag = String(m.output[0].substring ?? "")
            if let id = (try? Regex(#"\bid="([^"]+)""#).firstMatch(in: tag))?.output[1].substring, let href = (try? Regex(#"\bhref="([^"]+)""#).firstMatch(in: tag))?.output[1].substring {
                manifest[String(id)] = String(href).removingPercentEncoding ?? String(href)
            }
        }
        let spine = opf.matches(of: try Regex(#"<itemref\b[^>]*idref="([^"]+)""#)).compactMap { $0.output[1].substring.map(String.init) }
        let base = opfURL.deletingLastPathComponent()
        let out = NSMutableAttributedString()
        for id in spine {
            guard let href = manifest[id] else { continue }
            let chapter = base.appendingPathComponent(href)
            guard let data = try? Data(contentsOf: chapter),
                  let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue,
                                                                       .baseURL: chapter], documentAttributes: nil) else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            out.append(s)
        }
        if out.length == 0 { throw MarshmallowError("EPUB 沒有可讀取的內容") }
        return DocumentEngine.plainDefaults(out)
    }

    /// Writes an attributed string as a minimal, valid EPUB 3.
    static func writeEPUB(_ s: NSAttributedString, title: String, to out: URL) async throws {
        var body = ""
        let ns = s.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            var html = ""
            var maxSize: CGFloat = 0
            s.enumerateAttributes(in: range) { attrs, r, _ in
                var t = OfficeWriter.xmlEscape(ns.substring(with: r))
                if let f = attrs[.font] as? NSFont {
                    maxSize = max(maxSize, f.pointSize)
                    let traits = f.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { t = "<strong>\(t)</strong>" }
                    if traits.contains(.italic) { t = "<em>\(t)</em>" }
                }
                html += t
            }
            let tag = maxSize >= 20 ? "h1" : (maxSize >= 16 ? "h2" : "p")
            body += "<\(tag)>\(html)</\(tag)>\n"
        }
        let t = OfficeWriter.xmlEscape(title)
        let uid = UUID().uuidString
        let files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8)),
            ("OEBPS/content.opf", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(uid)</dc:identifier><dc:title>\(t)</dc:title><dc:language>zh-Hant</dc:language>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).prefix(19))Z</meta>
            </metadata>
            <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c1"/></spine></package>
            """.utf8)),
            ("OEBPS/nav.xhtml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head>
            <body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">\(t)</a></li></ol></nav></body></html>
            """.utf8)),
            ("OEBPS/chapter1.xhtml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(t)</title></head><body>
            \(body)</body></html>
            """.utf8)),
        ]
        try await OfficeWriter.package(files, to: out, stored: ["mimetype"])
    }
}

import PDFKit
enum PDFKitBridge {
    static func document(_ url: URL) -> PDFDocument? { PDFDocument(url: url) }
}
