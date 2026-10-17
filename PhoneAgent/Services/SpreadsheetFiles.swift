import Foundation

@MainActor
enum SpreadsheetFiles {
    static func excel(_ sheet: SpreadsheetDraft, title: String, chart: SheetChartSpec?) throws -> Data {
        let receipt = SheetReceipt(version: 1, title: "Sheet1", rows: sheet.rows, chart: chart ?? SheetChartSpec(valueColumns: sheet.columns > 1 ? [1] : [], lastRow: max(1, min(4, sheet.rows.count - 1))), chartEnabled: chart != nil)
        let item = WorkbookSheet(id: UUID(), name: "Sheet1", receipt: receipt)
        return try excel(WorkbookReceipt(version: 2, title: title, sheets: [item], selectedID: item.id))
    }
    static func excel(_ workbook: WorkbookReceipt) throws -> Data {
        let calculated = try workbook.calculated()
        var parts: [String: String] = [:], extras: [String: String] = [:]
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let sheetsXML = workbook.sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(ArtifactFiles.xml(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        let active = workbook.sheets.firstIndex(where: { $0.id == workbook.selectedID }) ?? 0
        parts["xl/workbook.xml"] = ArtifactFiles.header + "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(ArtifactFiles.relations)\"><bookViews><workbookView activeTab=\"\(active)\"/></bookViews><sheets>\(sheetsXML)</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        parts["xl/_rels/workbook.xml.rels"] = ArtifactFiles.relationships(workbook.sheets.indices.map { ("rId\($0 + 1)", "worksheet", "worksheets/sheet\($0 + 1).xml") } + [("styles", "styles", "styles.xml")])
        for (index, item) in workbook.sheets.enumerated() {
            do {
                let value = try worksheetParts(item.receipt.checked(), title: workbook.sheets.count == 1 ? workbook.title : item.name, chart: item.receipt.chartEnabled ? item.receipt.chart : nil, index: index + 1, name: item.name, values: calculated[index])
                parts.merge(value.parts) { _, new in new }; extras.merge(value.extras) { _, new in new }
            } catch { throw AgentError.message("Sheet \"\(item.name)\": " + error.localizedDescription) }
        }
        return try ArtifactFiles.package(main: "xl/workbook.xml", type: "spreadsheetml.sheet.main", extras: extras, body: parts)
    }
    private static func worksheetParts(_ sheet: SpreadsheetDraft, title: String, chart: SheetChartSpec?, index: Int, name: String, values: [[SheetValue]]) throws -> (parts: [String: String], extras: [String: String]) {
        guard title.count <= 120 else { throw AgentError.message("Sheet title can be up to 120 characters") }
        for row in values.indices { for column in values[row].indices {
            if case .error(let code) = values[row][column] { throw AgentError.message("\(SheetAddress(row: row, column: column).name): \(code). Fix it before exporting to Excel") }
        } }
        let points = try chart.map { try sheet.chart($0, values: values) }
        let xml = ArtifactFiles.xml
        let header = ArtifactFiles.header
        let relation = ArtifactFiles.relations
        let data = sheet.rows.enumerated().map { row, cells in
            "<row r=\"\(row + 1)\" ht=\"28\" customHeight=\"1\">" + cells.enumerated().map { column, raw in
                let ref = SheetAddress(row: row, column: column).name
                let open = "<c r=\"\(ref)\" s=\"\(row == 0 ? 1 : 0)\""
                switch values[row][column] {
                case .number(let value):
                    let input = raw.trimmingCharacters(in: .whitespaces)
                    let formula = input.hasPrefix("=") ? "<f>\(xml(String(input.dropFirst())))</f>" : ""
                    return open + ">\(formula)<v>\(value == 0 ? "0" : String(value))</v></c>"
                case .empty: return open + "/>"
                case .text(let value): return open + " t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                case .error: return "" // All errors were rejected above.
                }
            }.joined() + "</row>"
        }.joined()
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let columns = (1...sheet.columns).map { "<col min=\"\($0)\" max=\"\($0)\" width=\"22\" customWidth=\"1\"/>" }.joined()
        let styles = header + "<styleSheet xmlns=\"\(ns)\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Arial\"/></font><font><b/><sz val=\"11\"/><name val=\"Arial\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFE7EEF9\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"center\" wrapText=\"1\"/></xf><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyAlignment=\"1\"><alignment vertical=\"center\" wrapText=\"1\"/></xf></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        var parts = [
            "xl/styles.xml": styles,
            "xl/worksheets/sheet\(index).xml": header + "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(relation)\"><dimension ref=\"A1:\(SheetAddress(row: sheet.rows.count - 1, column: sheet.columns - 1).name)\"/><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"28\"/><cols>\(columns)</cols><sheetData>\(data)</sheetData>\(chart == nil ? "" : "<drawing r:id=\"drawing\"/>")</worksheet>"
        ]
        var extras = ["xl/worksheets/sheet\(index).xml": "spreadsheetml.worksheet", "xl/styles.xml": "spreadsheetml.styles"]
        if let chart, let points {
            parts["xl/worksheets/_rels/sheet\(index).xml.rels"] = ArtifactFiles.relationships([("drawing", "drawing", "../drawings/drawing\(index).xml")])
            parts["xl/drawings/_rels/drawing\(index).xml.rels"] = ArtifactFiles.relationships([("chart", "chart", "../charts/chart\(index).xml")])
            let col = sheet.columns + 1
            parts["xl/drawings/drawing\(index).xml"] = header + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><xdr:twoCellAnchor><xdr:from><xdr:col>\(col)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>\(col + 10)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>20</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"2\" name=\"Chart\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:r=\"\(relation)\" r:id=\"chart\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>"
            parts["xl/charts/chart\(index).xml"] = chartXML(spec: chart, points: points, title: title, sheetName: name)
            extras["xl/drawings/drawing\(index).xml"] = "drawing"
            extras["xl/charts/chart\(index).xml"] = "drawingml.chart"
        }
        return (parts, extras)
    }
    private static func chartXML(spec: SheetChartSpec, points: [SheetChartPoint], title: String, sheetName: String) -> String {
        let xml = ArtifactFiles.xml
        let reference = xml("'" + sheetName.replacingOccurrences(of: "'", with: "''") + "'")
        let series = spec.valueColumns.enumerated().map { index, column in
            let values = points.filter { $0.series == column }
            let letter = String(UnicodeScalar(65 + column)!)
            let labelLetter = String(UnicodeScalar(65 + spec.labelColumn)!)
            let cats = values.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\(xml($0.element.label))</c:v></c:pt>" }.joined()
            let nums = values.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\($0.element.value)</c:v></c:pt>" }.joined()
            return "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/><c:tx><c:v>\(xml(values[0].name))</c:v></c:tx><c:cat><c:strRef><c:f>\(reference)!$\(labelLetter)$\(spec.firstRow + 1):$\(labelLetter)$\(spec.lastRow + 1)</c:f><c:strCache><c:ptCount val=\"\(values.count)\"/>\(cats)</c:strCache></c:strRef></c:cat><c:val><c:numRef><c:f>\(reference)!$\(letter)$\(spec.firstRow + 1):$\(letter)$\(spec.lastRow + 1)</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(values.count)\"/>\(nums)</c:numCache></c:numRef></c:val>\(spec.kind == .line ? "<c:smooth val=\"0\"/>" : "")</c:ser>"
        }.joined()
        let plot = spec.kind == .column ? "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(series)<c:gapWidth val=\"150\"/><c:overlap val=\"0\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>" : "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(series)<c:marker val=\"1\"/><c:smooth val=\"0\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:lineChart>"
        return ArtifactFiles.header + "<c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><c:lang val=\"zh-CN\"/><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(xml(title))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title><c:plotArea><c:layout/>\(plot)<c:catAx><c:axId val=\"1\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:axPos val=\"b\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"2\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/></c:catAx><c:valAx><c:axId val=\"2\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:axPos val=\"l\"/><c:majorGridlines/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"1\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"between\"/></c:valAx></c:plotArea><c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend><c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart></c:chartSpace>"
    }
    static func csv(_ sheet: SpreadsheetDraft, values supplied: [[SheetValue]]? = nil) throws -> Data {
        try sheet.validate()
        let values = try supplied ?? sheet.calculated()
        guard values.count == sheet.rows.count, values.allSatisfy({ $0.count == sheet.columns }) else { throw AgentError.message("Calculated results don't match the sheet size") }
        for row in values { if row.contains(where: { if case .error = $0 { return true }; return false }) { throw AgentError.message("Fix formula errors before exporting calculated values as CSV") } }
        let content = values.map { row in row.map { value -> String in
            let text = value.display
            let first = text.trimmingCharacters(in: .whitespaces).first
            let safe = ["=", "+", "-", "@"].contains(first.map(String.init) ?? "") && { if case .text = value { return true }; return false }() ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + content).utf8)
    }
    static func svg(_ sheet: SpreadsheetDraft, title: String, chart: SheetChartSpec, values supplied: [[SheetValue]]? = nil) throws -> Data {
        guard title.count <= 120 else { throw AgentError.message("Chart title can be up to 120 characters") }
        let points = try sheet.chart(chart, values: supplied ?? sheet.calculated())
        let categories = points.filter { $0.series == chart.valueColumns[0] }
        let width = max(900, categories.count * 90 + 150)
        let plotWidth = Double(width - 150)
        let low = min(0, points.map(\.value).min() ?? 0), high = max(0, points.map(\.value).max() ?? 0)
        let span = high == low ? 1 : high - low
        let colors = ["#3478F6", "#14A085", "#C85B9B"]
        func y(_ value: Double) -> Double { 400 - (value - low) / span * 280 }
        func x(_ index: Int) -> Double { 100 + (Double(index) + 0.5) / Double(categories.count) * plotWidth }
        func text(_ value: String, x: Double, y: Double, size: Int = 14, color: String = "#202124", anchor: String = "middle") -> String { "<text x=\"\(x)\" y=\"\(y)\" fill=\"\(color)\" font-size=\"\(size)\" text-anchor=\"\(anchor)\">\(ArtifactFiles.xml(value))</text>" }
        func wrapped(_ value: String, x: Double, y: Double, width: Int = 10) -> String {
            let chars = Array(value); var result = ""
            for start in stride(from: 0, to: chars.count, by: width) { result += text(String(chars[start..<min(chars.count, start + width)]), x: x, y: y + Double(start / width * 18)) }
            return result
        }
        let labelHeight = categories.map { Int(ceil(Double($0.label.count) / 10)) }.max() ?? 1
        let height = 450 + labelHeight * 18 + 3 * 60
        var body = "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>" + wrapped(title, x: Double(width)/2, y: 35, width: 50)
        for index in 0...4 {
            let value = low + span * Double(index) / 4
            body += "<path d=\"M100 \(y(value)) H\(width - 50)\" stroke=\"#E4E7EB\"/>"
            body += text(String(format: "%.5g", value), x: 88, y: y(value) + 5, size: 13, anchor: "end")
        }
        body += "<path d=\"M100 \(y(0)) H\(width - 50)\" stroke=\"#202124\"/>"
        for (seriesIndex, column) in chart.valueColumns.enumerated() {
            let values = points.filter { $0.series == column }
            if chart.kind == .line {
                let path = values.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(x($0.offset)) \(y($0.element.value))" }.joined(separator: " ")
                body += "<path d=\"\(path)\" stroke=\"\(colors[seriesIndex])\" stroke-width=\"3\" fill=\"none\"/>"
                for (index, value) in values.enumerated() { body += "<circle cx=\"\(x(index))\" cy=\"\(y(value.value))\" r=\"4\" fill=\"\(colors[seriesIndex])\"><title>\(ArtifactFiles.xml(value.label + " · " + value.name + " · " + String(value.value)))</title></circle>" }
            } else {
                let bar = min(24, plotWidth / Double(categories.count) * 0.75 / Double(chart.valueColumns.count))
                for (index, value) in values.enumerated() {
                    let left = x(index) + (Double(seriesIndex) - Double(chart.valueColumns.count)/2) * bar
                    body += "<rect x=\"\(left)\" y=\"\(min(y(0), y(value.value)))\" width=\"\(bar - 2)\" height=\"\(abs(y(value.value)-y(0)))\" fill=\"\(colors[seriesIndex])\"><title>\(ArtifactFiles.xml(value.label + " · " + value.name + " · " + String(value.value)))</title></rect>"
                }
            }
            body += wrapped(values[0].name, x: Double(width)/2, y: Double(450 + labelHeight * 18 + seriesIndex * 60), width: 50)
            body += "<rect x=\"\(width/2 - 220)\" y=\"\(438 + labelHeight * 18 + seriesIndex * 60)\" width=\"14\" height=\"14\" fill=\"\(colors[seriesIndex])\"/>"
        }
        for (index, value) in categories.enumerated() { body += wrapped(value.label, x: x(index), y: 428) }
        return Data(("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\"><title>\(ArtifactFiles.xml(title))</title><g font-family=\"Arial, PingFang SC, sans-serif\">\(body)</g></svg>").utf8)
    }
}
