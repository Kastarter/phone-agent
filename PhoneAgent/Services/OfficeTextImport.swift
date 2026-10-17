import Foundation
import zlib

// Reads text from bounded OOXML packages. It never extracts files, evaluates
// formulas/macros, resolves external entities, or follows external relationships.
enum OfficeTextImport {
    private struct Part { var name: String; var offset: Int; var size: Int; var compressed: Int; var method: Int; var checksum: UInt32 }
    static func read(_ data: Data, ext: String) throws -> String {
        guard data.count <= 5_000_000 else { throw AgentError.message("Office import files must be 5 MB or smaller") }
        let parts = try archive(data)
        func parse(_ name: String, mode: Collector.Mode = .text, shared: [String] = []) throws -> Collector {
            guard let bytes = parts[name] else { throw AgentError.message("Office document is missing a required text part") }
            let leading = Array(bytes.prefix(4))
            let encoding: String.Encoding
            if leading.starts(with: [0xFF, 0xFE]) || leading == [0x3C, 0x00, 0x3F, 0x00] { encoding = .utf16LittleEndian }
            else if leading.starts(with: [0xFE, 0xFF]) || leading == [0x00, 0x3C, 0x00, 0x3F] { encoding = .utf16BigEndian }
            else { encoding = .utf8 }
            guard let text = String(data: bytes, encoding: encoding), !text.contains("\0") else {
                throw AgentError.message("Office text parts must be UTF-8 / UTF-16 XML")
            }
            guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw AgentError.message("Documents with entity declarations aren't supported") }
            let collector = Collector(mode: mode, shared: shared)
            let parser = XMLParser(data: bytes); parser.delegate = collector; parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never
            guard parser.parse(), !collector.tooLarge else { throw AgentError.message("Office text is invalid or out of range: up to 12000 characters, 200 rows and 26 columns per sheet") }
            return collector
        }
        func orderedParts(root: String, manifest: String, relation: String, element: String) throws -> [(String, String)] {
            let listed = try parse(manifest, mode: .manifest(element)).items
            let links = try parse(relation, mode: .relationships).items
            var result: [(String, String)] = []
            for (id, label) in listed {
                guard let link = links.first(where: { $0.0 == id })?.1, !link.contains(":"), !link.hasPrefix("//") else { throw AgentError.message("Document contains unsupported external or missing relationships") }
                var segments = link.hasPrefix("/") ? [] : root.components(separatedBy: "/")
                for piece in link.components(separatedBy: "/") where !piece.isEmpty && piece != "." {
                    if piece == ".." { guard !segments.isEmpty else { throw AgentError.message("Invalid document relationship path") }; segments.removeLast() }
                    else { segments.append(piece) }
                }
                result.append((segments.joined(separator: "/"), label))
            }
            return result
        }
        let result: String
        switch ext {
        case "docx": result = try parse("word/document.xml").text
        case "pptx":
            let slides = try orderedParts(root: "ppt", manifest: "ppt/presentation.xml", relation: "ppt/_rels/presentation.xml.rels", element: "sldId")
            guard (1...30).contains(slides.count) else { throw AgentError.message("Imported PPT must have 1–30 slides") }
            result = try slides.enumerated().map { "Slide \($0.offset+1)\n" + (try parse($0.element.0).text) }.joined(separator: "\n---\n")
        case "xlsx":
            let shared = parts["xl/sharedStrings.xml"] == nil ? [] : try parse("xl/sharedStrings.xml", mode: .strings).strings
            let sheets = try orderedParts(root: "xl", manifest: "xl/workbook.xml", relation: "xl/_rels/workbook.xml.rels", element: "sheet")
            guard (1...12).contains(sheets.count) else { throw AgentError.message("Imported Excel must have 1–12 sheets") }
            result = try sheets.map { "Sheet: \($0.1)\n" + (try parse($0.0, mode: .sheet, shared: shared).text) }.joined(separator: "\n\n")
        default: throw AgentError.message("Unsupported Office format")
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.count <= 12000 else { throw AgentError.message("Office document has no extractable text or exceeds 12000 characters. Split it first; nothing was truncated.") }
        return result
    }
    private static func archive(_ data: Data) throws -> [String: Data] {
        func number(_ offset: Int, _ bytes: Int) throws -> UInt32 {
            guard offset >= 0, offset + bytes <= data.count else { throw AgentError.message("Office archive is incomplete") }
            return (0..<bytes).reduce(UInt32(0)) { $0 | UInt32(data[offset+$1]) << (8*$1) }
        }
        guard data.count >= 22 else { throw AgentError.message("Invalid Office archive") }
        var end: Int?
        for offset in stride(from: data.count-22, through: max(0, data.count-65557), by: -1) {
            if try number(offset, 4) == 0x06054B50, offset + 22 + Int(try number(offset+20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end+4, 2) == 0, try number(end+6, 2) == 0,
              try number(end+8, 2) == number(end+10, 2) else { throw AgentError.message("Split or Zip64 Office files aren't supported") }
        let count = Int(try number(end+10, 2)), directory = Int(try number(end+16, 4)), length = Int(try number(end+12, 4))
        guard count <= 500, directory + length <= end else { throw AgentError.message("Office document has too many parts or an invalid directory") }
        var offset = directory, selected: [Part] = [], names = Set<String>(), total = 0
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014B50 else { throw AgentError.message("Invalid Office archive directory") }
            let flags = try number(offset+8, 2), method = Int(try number(offset+10, 2)), compressed = Int(try number(offset+20, 4)), size = Int(try number(offset+24, 4))
            let nameLength = Int(try number(offset+28, 2)), extra = Int(try number(offset+30, 2)), comment = Int(try number(offset+32, 2))
            guard flags & 1 == 0, nameLength <= 1024, offset+46+nameLength+extra+comment <= directory+length,
                  let name = String(data: data.subdata(in: offset+46..<offset+46+nameLength), encoding: .utf8), names.insert(name).inserted else { throw AgentError.message("Encrypted, duplicate, or invalid Office file parts aren't supported") }
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                total += size
                guard size <= 2_000_000, total <= 8_000_000, [0,8].contains(method) else { throw AgentError.message("Office text is too large when decompressed, or the compression method isn't supported") }
                selected.append(Part(name: name, offset: Int(try number(offset+42, 4)), size: size, compressed: compressed, method: method, checksum: try number(offset+16, 4)))
            }
            offset += 46+nameLength+extra+comment
        }
        guard offset == directory+length else { throw AgentError.message("Office archive directory length mismatch") }
        var parts: [String: Data] = [:]
        for part in selected {
            try Task.checkCancellation()
            guard try number(part.offset, 4) == 0x04034B50, try number(part.offset+6, 2) & 1 == 0, Int(try number(part.offset+8, 2)) == part.method else { throw AgentError.message("Invalid Office file part header") }
            let localNameSize = Int(try number(part.offset+26, 2))
            let start = part.offset + 30 + localNameSize + Int(try number(part.offset+28, 2))
            guard part.offset + 30 + localNameSize <= directory,
                  String(data: data.subdata(in: part.offset+30..<part.offset+30+localNameSize), encoding: .utf8) == part.name else {
                throw AgentError.message("Office file part name mismatch")
            }
            guard start + part.compressed <= directory else { throw AgentError.message("Office file part out of range") }
            let input = data.subdata(in: start..<start+part.compressed)
            let output: Data
            if part.method == 0 { output = input }
            else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AgentError.message("Can't initialize Office decompression") }
                defer { inflateEnd(&stream) }
                var bytes = [UInt8](repeating: 0, count: max(1,part.size))
                let status = input.withUnsafeBytes { raw in bytes.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                } }
                guard status == Z_STREAM_END, stream.total_out == part.size, stream.total_in == part.compressed else { throw AgentError.message("Office file decompression didn't finish completely") }
                output = Data(bytes.prefix(part.size))
            }
            let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
            guard output.count == part.size, UInt32(checksum) == part.checksum else { throw AgentError.message("Office file checksum failed") }
            parts[part.name] = output
        }
        return parts
    }
    private final class Collector: NSObject, XMLParserDelegate {
        enum Mode { case text, sheet, strings, relationships, manifest(String) }
        let mode: Mode, shared: [String]
        var text = "", strings: [String] = [], items: [(String,String)] = [], tooLarge = false
        private var sharedSize = 0
        private var namespacePrefixes: [String: [String]] = [:]
        private var relationshipIDs = Set<String>(), manifestIDs = Set<String>(), cellColumns = Set<Int>()
        private var inRow = false
        private var phoneticDepth = 0
        private var formula = false, cachedValue = false
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { namespacePrefixes[prefix, default: []].append(uri) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespacePrefixes[prefix]?.popLast() }
        private var capture = false, value = "", cell = "", kind = "", row: [String] = [], column = 0, rows = 0
        init(mode: Mode, shared: [String]) { self.mode = mode; self.shared = shared }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch mode {
            case .relationships:
                if name == "Relationship" {
                    guard let id = attributes["Id"], !id.isEmpty, let target = attributes["Target"],
                          relationshipIDs.insert(id).inserted else { parser.abortParsing(); return }
                    if attributes["TargetMode"] != "External" { items.append((id, target)) }
                }
            case .manifest(let target):
                if name == target {
                    let ids = attributes.compactMap { key, value -> String? in
                        let pieces = key.split(separator: ":", omittingEmptySubsequences: false)
                        guard pieces.count == 2, pieces[1] == "id", let uri = namespacePrefixes[String(pieces[0])]?.last,
                              ["http://schemas.openxmlformats.org/officeDocument/2006/relationships", "http://purl.oclc.org/ooxml/officeDocument/relationships"].contains(uri) else { return nil }
                        return value
                    }
                    guard ids.count == 1, !ids[0].isEmpty, manifestIDs.insert(ids[0]).inserted else { parser.abortParsing(); return }
                    items.append((ids[0], attributes["name"] ?? ""))
                }
            case .sheet:
                if name == "row" {
                    let next = attributes["r"].flatMap(Int.init) ?? (attributes["r"] == nil ? rows + 1 : 0)
                    guard !inRow, next > rows, next <= 200 else { tooLarge = true; parser.abortParsing(); return }
                    text += String(repeating: "\n", count: next - rows - 1)
                    row = []; rows = next; inRow = true; cellColumns.removeAll()
                }
                if name == "c" {
                    guard inRow else { parser.abortParsing(); return }
                    cell = ""; kind = attributes["t"] ?? ""; column = 0; formula = false; cachedValue = false
                    if let reference = attributes["r"] {
                        guard reference.utf8.count <= 8 else { tooLarge = true; parser.abortParsing(); return }
                        let letters = reference.unicodeScalars.prefix(while: { (65...90).contains($0.value) })
                        let digits = String(reference.dropFirst(letters.count))
                        guard !letters.isEmpty, letters.count <= 3, !digits.isEmpty,
                              digits.allSatisfy({ $0.isASCII && $0.isNumber }), Int(digits) == rows else { parser.abortParsing(); return }
                        for char in letters { column = column*26 + Int(char.value)-64 }; column -= 1
                    } else { column = row.count }
                    guard (0..<26).contains(column) else { tooLarge = true; parser.abortParsing(); return }
                    guard cellColumns.insert(column).inserted else { parser.abortParsing(); return }
                }
                if name == "f" { formula = true }
                if name == "rPh" { phoneticDepth += 1 }
                if (name == "t" && phoneticDepth == 0) || name == "v" { capture = true; value = "" }
            case .strings:
                if name == "si" { cell = "" }
                if name == "rPh" { phoneticDepth += 1 }
                if name == "t", phoneticDepth == 0 { capture = true; value = "" }
            case .text: if name == "t" { capture = true; value = "" }; if name == "tab" { text += "\t" }; if name == "br" { text += "\n" }
            }
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let string = String(data: data, encoding: .utf8) else { parser.abortParsing(); return }
            self.parser(parser, foundCharacters: string)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capture { value += string; if value.count > 12000 { tooLarge = true; parser.abortParsing() } }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch mode {
            case .text: if name == "t" { text += value; capture = false }; if name == "p" { text += "\n" }
            case .strings:
                if name == "t", phoneticDepth == 0 { cell += value; capture = false }
                if name == "rPh" { phoneticDepth = max(0, phoneticDepth - 1) }
                if name == "si" { strings.append(cell); sharedSize += cell.count; if strings.count > 10000 || sharedSize > 100000 { tooLarge = true; parser.abortParsing() } }
            case .sheet:
                if name == "t", phoneticDepth == 0 { cell += value; capture = false }
                if name == "v" { cell += value; cachedValue = !value.isEmpty; capture = false }
                if name == "rPh" { phoneticDepth = max(0, phoneticDepth - 1) }
                if name == "c" {
                    if kind == "s" { if let index = Int(cell), shared.indices.contains(index) { cell = shared[index] } else { tooLarge = true; parser.abortParsing(); return } }
                    if formula && !cachedValue { cell = "[Formula has no cached value; not calculated]" }
                    if kind == "b", cachedValue { cell = cell == "1" ? "TRUE" : cell == "0" ? "FALSE" : cell }
                    while row.count <= column { row.append("") }; if row.indices.contains(column) { row[column] = cell }
                }
                if name == "row" { text += row.joined(separator: "\t") + "\n"; inRow = false }
            default: break
            }
            if text.count > 12000 { tooLarge = true; parser.abortParsing() }
        }
    }
}
