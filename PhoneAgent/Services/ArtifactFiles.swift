import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreText

enum ArtifactFormat: String, CaseIterable, Identifiable {
    case text = "Text", markdown = "Markdown", pdf = "PDF", word = "Word", excel = "Excel", slides = "PPT", csv = "CSV"
    var id: String { rawValue }
    var ext: String {
        switch self { case .text: return "txt"; case .markdown: return "md"; case .pdf: return "pdf"; case .word: return "docx"; case .excel: return "xlsx"; case .slides: return "pptx"; case .csv: return "csv" }
    }
    var type: UTType { UTType(filenameExtension: ext) ?? .data }
    var instruction: String {
        switch self {
        case .excel, .csv: return "Return only table text with tab-separated columns and one row per line; the first row is the header. At most 200 rows and 26 columns. No Markdown tables, code blocks, formulas, or macros."
        case .slides: return "Return only slide text. The first line of each slide is the title; remaining lines are bullet points. Separate slides with a line containing only ---. Each slide has at most 7 lines and 400 characters, titles at most 80 characters, and at most 30 slides."
        default: return "Return only the document content in short paragraphs; no code blocks or action JSON."
        }
    }
}

struct ArtifactDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// A bounded ZIP writer for our own OOXML parts. No archives are opened or executed.
enum StoredZIP {
    static func make(_ parts: [String: String]) throws -> Data {
        guard parts.count <= 200 else { throw AgentError.message("Too many file parts") }
        var data = Data(), central = Data()
        func word(_ value: UInt16, into target: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { target.append(contentsOf: $0) } }
        func long(_ value: UInt32, into target: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { target.append(contentsOf: $0) } }
        func crc(_ bytes: Data) -> UInt32 {
            var value = UInt32.max
            for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0) } }
            return value ^ UInt32.max
        }
        for (name, content) in parts.sorted(by: { $0.key < $1.key }) {
            let file = Data(content.utf8), filename = Data(name.utf8), offset = UInt32(data.count), checksum = crc(file)
            guard file.count < 4_000_000, filename.count < 1000, data.count < 10_000_000 else { throw AgentError.message("File is too large") }
            long(0x04034B50, into: &data); word(20, into: &data); word(0x0800, into: &data); word(0, into: &data)
            word(0, into: &data); word(33, into: &data); long(checksum, into: &data); long(UInt32(file.count), into: &data); long(UInt32(file.count), into: &data)
            word(UInt16(filename.count), into: &data); word(0, into: &data); data.append(filename); data.append(file)
            long(0x02014B50, into: &central); word(20, into: &central); word(20, into: &central); word(0x0800, into: &central); word(0, into: &central)
            word(0, into: &central); word(33, into: &central); long(checksum, into: &central); long(UInt32(file.count), into: &central); long(UInt32(file.count), into: &central)
            word(UInt16(filename.count), into: &central); word(0, into: &central); word(0, into: &central); word(0, into: &central); word(0, into: &central)
            long(0, into: &central); long(offset, into: &central); central.append(filename)
        }
        let offset = UInt32(data.count); data.append(central)
        long(0x06054B50, into: &data); word(0, into: &data); word(0, into: &data); word(UInt16(parts.count), into: &data); word(UInt16(parts.count), into: &data)
        long(UInt32(central.count), into: &data); long(offset, into: &data); word(0, into: &data)
        return data
    }
}

@MainActor
enum ArtifactFiles {
    static func make(title: String, text: String, format: ArtifactFormat) throws -> Data {
        guard !text.isEmpty, text.count <= 12000, title.count <= 120 else { throw AgentError.message("Title must be at most 120 characters and content 1–12000 characters") }
        switch format {
        case .text, .markdown: return Data((title + "\n\n" + text).utf8)
        case .pdf: return try pdf(title: title, text: text)
        case .word:
            let body = ([title] + lines(text)).enumerated().map { index, line in
                "<w:p><w:r><w:rPr><w:rFonts w:ascii=\"Aptos\" w:eastAsia=\"PingFang SC\"/>\(index == 0 ? "<w:b/>" : "")<w:sz w:val=\"\(index == 0 ? 36 : 24)\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(line))</w:t></w:r></w:p>"
            }.joined()
            return try package(main: "word/document.xml", type: "wordprocessingml.document.main", extras: [:], body: ["word/document.xml": header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:right=\"1440\"/></w:sectPr></w:body></w:document>"])
        case .excel, .csv:
            let rows = try table(text)
            if format == .csv {
                let content = rows.map { row in row.map { cell -> String in
                    let first = cell.trimmingCharacters(in: .whitespaces).first
                    let safe = ["=", "+", "-", "@"].contains(first.map(String.init) ?? "") ? "'" + cell : cell
                    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }.joined(separator: ",") }.joined(separator: "\r\n")
                return Data(("\u{FEFF}" + content).utf8)
            }
            let columnCount = rows.map(\.count).max() ?? 1
            // CJK scalars occupy roughly two Latin columns. Bound display widths;
            // the cell value itself is never shortened to fit the layout.
            func displayWidth(_ value: String) -> Int {
                value.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
            }
            let widths = (0..<columnCount).map { column in
                min(44, max(16, rows.map { column < $0.count ? displayWidth($0[column]) + 3 : 0 }.max() ?? 16))
            }
            let columns = widths.enumerated().map { index, width in
                "<col min=\"\(index+1)\" max=\"\(index+1)\" width=\"\(width)\" customWidth=\"1\"/>"
            }.joined()
            let sheet = rows.enumerated().map { r, row in
                let lineCount = row.enumerated().map { c, cell in
                    max(1, Int(ceil(Double(displayWidth(cell)) / Double(max(1, widths[c] - 2)))))
                }.max() ?? 1
                let height = min(409, max(r == 0 ? 28 : 24, lineCount * 18 + 8))
                return "<row r=\"\(r+1)\" ht=\"\(height)\" customHeight=\"1\">" + row.enumerated().map { c, cell in
                    let reference = String(UnicodeScalar(65+c)!) + String(r+1)
                    return "<c r=\"\(reference)\" s=\"\(r == 0 ? 1 : 0)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(cell))</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            let range = "A1:" + String(UnicodeScalar(64+columnCount)!) + String(rows.count)
            let styles = header + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"PingFang SC\"/><color rgb=\"FF171717\"/></font><font><b/><sz val=\"11\"/><name val=\"PingFang SC\"/><color rgb=\"FF171717\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFF0F2F5\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left style=\"thin\"><color rgb=\"FFDADDE2\"/></left><right style=\"thin\"><color rgb=\"FFDADDE2\"/></right><top style=\"thin\"><color rgb=\"FFDADDE2\"/></top><bottom style=\"thin\"><color rgb=\"FFDADDE2\"/></bottom><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyBorder=\"1\" applyAlignment=\"1\"><alignment vertical=\"center\" wrapText=\"1\" indent=\"1\"/></xf><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment vertical=\"center\" wrapText=\"1\" indent=\"1\"/></xf></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
            return try package(main: "xl/workbook.xml", type: "spreadsheetml.sheet.main", extras: ["xl/worksheets/sheet1.xml": "spreadsheetml.worksheet", "xl/styles.xml": "spreadsheetml.styles"], body: [
                "xl/workbook.xml": header + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(relations)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
                "xl/_rels/workbook.xml.rels": relationships([("rId1", "worksheet", "worksheets/sheet1.xml"), ("rId2", "styles", "styles.xml")]),
                "xl/styles.xml": styles,
                "xl/worksheets/sheet1.xml": header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"\(range)\"/><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"24\"/><cols>\(columns)</cols><sheetData>\(sheet)</sheetData><printOptions headings=\"0\" gridLines=\"0\"/><pageMargins left=\"0.5\" right=\"0.5\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/><pageSetup paperSize=\"9\" orientation=\"\(columnCount > 6 ? "landscape" : "portrait")\"/></worksheet>"
            ])
        case .slides: return try presentation(text)
        }
    }
    static func filename(_ title: String) -> String {
        let name = title.filter { !$0.isNewline && !"/:\\?%*|\"<>".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Phone Agent" : String(name.prefix(80))
    }
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static let relations = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static func xml(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF })
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func relationships(_ values: [(String, String, String)]) -> String {
        header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + values.map {
            "<Relationship Id=\"\($0.0)\" Type=\"\(relations)/\($0.1)\" Target=\"\($0.2)\"/>"
        }.joined() + "</Relationships>"
    }
    static func package(main: String, type: String, extras: [String: String], body: [String: String]) throws -> Data {
        var parts = body
        var contentTypes = "<Override PartName=\"/\(main)\" ContentType=\"application/vnd.openxmlformats-officedocument.\(type)+xml\"/>"
        for (name, type) in extras.sorted(by: { $0.key < $1.key }) { contentTypes += "<Override PartName=\"/\(name)\" ContentType=\"application/vnd.openxmlformats-officedocument.\(type)+xml\"/>" }
        parts["[Content_Types].xml"] = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(contentTypes)</Types>"
        parts["_rels/.rels"] = relationships([("rId1", "officeDocument", main)])
        return try StoredZIP.make(parts)
    }
    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)
    }
    private static func table(_ text: String) throws -> [[String]] {
        var source = lines(text)
        // A final newline is a record terminator. Interior empty rows retain their
        // positions; CRLF is one newline, never a second accidental blank row.
        if source.count > 1, source.last == "" { source.removeLast() }
        let rows = source.map { $0.components(separatedBy: "\t") }
        guard !rows.isEmpty, rows.count <= 200, rows.allSatisfy({ $0.count <= 26 && $0.allSatisfy({ $0.count <= 3000 }) }) else { throw AgentError.message("Tables allow at most 200 rows, 26 columns, and 3000 characters per cell. Separate columns with tabs") }
        return rows
    }
    // Core Graphics/Core Text have the same PDF path on iOS and macOS. No
    // platform view renderer or screenshot is needed to generate a document.
    private static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.09, alpha: 1)
        ])
    }
    private static func pdf(title: String, text: String) throws -> Data {
        let string = title.isEmpty ? text : title + "\n\n" + text
        let content = NSMutableAttributedString(attributedString: attributed(string, size: 16))
        if !title.isEmpty {
            let range = NSRange(location: 0, length: (title as NSString).length)
            content.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil), range: range)
        }
        var spacing: CGFloat = 5
        withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
            let style = CTParagraphStyleCreate(&setting, 1)
            content.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style, range: NSRange(location: 0, length: content.length))
        }
        let setter = CTFramesetterCreateWithAttributedString(content)
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw AgentError.message("Could not create PDF")
        }
        var offset = 0, number = 0
        while offset < content.length {
            try Task.checkCancellation()
            guard number < 100 else { context.closePDF(); throw AgentError.message("PDF exceeds 100 pages. Remove blank lines or split it; nothing was truncated") }
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), CGPath(rect: page.insetBy(dx: 44, dy: 48), transform: nil), nil)
            let count = CTFrameGetVisibleStringRange(frame).length
            guard count > 0 else { context.closePDF(); throw AgentError.message("PDF pagination stalled and the file was not exported; adjust the text") }
            context.beginPDFPage(nil); CTFrameDraw(frame, context)
            number += 1
            let footer = CTLineCreateWithAttributedString(attributed("\(number)", size: 10))
            context.textPosition = CGPoint(x: 288, y: 24); CTLineDraw(footer, context)
            context.endPDFPage(); offset += count
        }
        context.closePDF()
        return bytes as Data
    }
    private static func presentation(_ text: String) throws -> Data {
        var slides: [[String]] = [[]]
        for line in lines(text) {
            if line.trimmingCharacters(in: .whitespaces) == "---" { slides.append([]) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { slides[slides.count-1].append(line) }
        }
        slides = slides.filter { !$0.isEmpty }
        guard (1...30).contains(slides.count), slides.allSatisfy({ $0.count <= 7 && $0[0].count <= 80 && $0.joined().count <= 400 }) else { throw AgentError.message("Slides allow at most 30 slides, 7 lines and 400 characters each, titles up to 80 characters; separate slides with a line containing only ---") }
        let ns = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(relations)\""
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        var body: [String: String] = [:], extras: [String: String] = [:]
        let ids = slides.indices.map { "<p:sldId id=\"\(256+$0)\" r:id=\"s\($0+1)\"/>" }.joined()
        body["ppt/presentation.xml"] = header + "<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        body["ppt/_rels/presentation.xml.rels"] = relationships([("master", "slideMaster", "slideMasters/slideMaster1.xml")] + slides.indices.map { ("s\($0+1)", "slide", "slides/slide\($0+1).xml") })
        for (index, lines) in slides.enumerated() {
            let name = "ppt/slides/slide\(index+1).xml"; extras[name] = "presentationml.slide"
            func shape(_ id: Int, _ paragraphs: [String], y: Int, height: Int, font: Int, bold: Bool) -> String {
                let content = paragraphs.map { line in
                    "<a:p><a:pPr marL=\"0\" marR=\"0\"><a:lnSpc><a:spcPct val=\"115000\"/></a:lnSpc><a:spcAft><a:spcPts val=\"600\"/></a:spcAft></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"\(font)\" b=\"\(bold ? 1 : 0)\"><a:solidFill><a:srgbClr val=\"171717\"/></a:solidFill><a:latin typeface=\"Arial\"/><a:ea typeface=\"PingFang SC\"/></a:rPr><a:t>\(xml(line))</a:t></a:r></a:p>"
                }.joined()
                return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"700000\" y=\"\(y)\"/><a:ext cx=\"10700000\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" rIns=\"0\" tIns=\"0\" bIns=\"0\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(content)</p:txBody></p:sp>"
            }
            let shapes = shape(2, [lines[0]], y: 450000, height: 1350000, font: 2800, bold: true)
                + (lines.count > 1 ? shape(3, Array(lines.dropFirst()), y: 2000000, height: 4250000, font: 2100, bold: false) : "")
            body[name] = header + "<p:sld \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(group)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            body["ppt/slides/_rels/slide\(index+1).xml.rels"] = relationships([("layout", "slideLayout", "../slideLayouts/slideLayout1.xml")])
        }
        body["ppt/slideLayouts/slideLayout1.xml"] = header + "<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        body["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([("master", "slideMaster", "../slideMasters/slideMaster1.xml")])
        body["ppt/slideMasters/slideMaster1.xml"] = header + "<p:sldMaster \(ns)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"layout\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"
        body["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([("layout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "theme", "../theme/theme1.xml")])
        let colors = [("dk1", "171717"), ("lt1", "FFFFFF"), ("dk2", "353535"), ("lt2", "EEEEEE"), ("accent1", "246BFD"), ("accent2", "33AA88"), ("accent3", "AA55CC"), ("accent4", "CC9933"), ("accent5", "DD5566"), ("accent6", "4499AA"), ("hlink", "246BFD"), ("folHlink", "7755AA")].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"12700\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        body["ppt/theme/theme1.xml"] = header + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Phone Agent\"><a:themeElements><a:clrScheme name=\"Phone Agent\">\(colors)</a:clrScheme><a:fontScheme name=\"Phone Agent\"><a:majorFont><a:latin typeface=\"Aptos\"/><a:ea typeface=\"PingFang SC\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Aptos\"/><a:ea typeface=\"PingFang SC\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Phone Agent\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        extras["ppt/slideLayouts/slideLayout1.xml"] = "presentationml.slideLayout"; extras["ppt/slideMasters/slideMaster1.xml"] = "presentationml.slideMaster"; extras["ppt/theme/theme1.xml"] = "theme"
        return try package(main: "ppt/presentation.xml", type: "presentationml.presentation.main", extras: extras, body: body)
    }
}
